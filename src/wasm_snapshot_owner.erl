-module(wasm_snapshot_owner).
-moduledoc """
One process per loaded image, holding what an Erlang term cannot hold for
itself. Every worker on a node that shares the image holds it through this one
process.

An image is a term and the BEAM will collect it, but a term cannot say "I am
gone", and two things have to be given back when it is: the image's claim on
its module, and its hold on the keeper's record of its pages, which carries
its share of the node-wide byte budget. So each image gets a process whose life
matches its own, and whose only job is to know who still wants it.

The pages can outlive this process. A memory restored from the image reads
them in place, so the keeper keeps them charged until the last such memory is
gone as well; this process only gives up the image's own hold.

## Why this is its own module

`docs/architecture.md` names three cycles and `wasm_architecture_SUITE` asserts
them, so joining one is a decision rather than a side effect. Holding a claim
means calling `wasm_module_cache`, and the cache calls `wasm:compile/2` on a
miss, so **anything long-lived that holds a claim and is reachable from the
facade is in that cycle**. There is no arrangement that avoids it, only a
choice of which module joins.

This one does, and `wasm_snapshot` stays out. The mechanism -- what a capture
copies and what a restore lays over -- is then a module with no cycle in it,
and what joins the knot is fifty lines whose entire purpose is to hold a claim.

## What it is not

Not the keeper, though it holds a keeper record. Who still wants an image is
a set of processes, and the keeper's records are about resources: the byte
charge and the pages live there, beside the memories that read them, and this
process is the image's holder of that record.

It also makes invalidation fall out rather than be enforced. The claim is made
for this process, so it dies when this process does, and the cache is what
sees to that.

## The live flag

An image carries a one-element `atomics` array this process makes, 1 while new
restores are allowed and 0 for ever after. This process clears it when its
last holder goes, and the keeper clears it again when it sees this process go
for any reason, `kill` included. `wasm:restore/3` reads it rather than asking
this process, so a pool of workers sharing one image never queues on one
mailbox to restore.
""".

-export([start/3, abandon/1, acquire/2, acquire/3, release/2, holders/1]).
-export([charged/0]).

-include("wasm_snapshot_budget.hrl").

-define(ASK_TIMEOUT, 5_000).

-doc """
Start an owner holding `Handle` for `FirstHolder`, charge the image's `Bytes`
and register its pages with the keeper, answering the owner and the keeper's
record for the image.

The claim is taken here rather than by the caller, because a claim belongs to
the process that will give it back. The owner watches `FirstHolder` from the
start, so a caller that dies while it builds the image's pages gives the charge
and the claim back with it; one that fails to build and lives calls
`abandon/1`. Nothing of the image itself passes through this process: a copy
into it and back measured up to 0.6 ms of a CPython load.
""".
-spec start(wasm_module_cache:handle(), non_neg_integer(), pid()) ->
          {ok, pid(), wasm_keeper:resource(), atomics:atomics_ref()}
        | {error, not_loaded | wasm_error:error()}.
start(Handle, Bytes, FirstHolder) ->
    Self = self(),
    Ref = make_ref(),
    Owner = spawn(fun() -> init(Self, Ref, Handle, Bytes, FirstHolder) end),
    Mon = erlang:monitor(process, Owner),
    receive
        {Ref, {ok, Img, Live}} ->
            erlang:demonitor(Mon, [flush]),
            {ok, Owner, Img, Live};
        {Ref, {error, _} = Error} ->
            erlang:demonitor(Mon, [flush]),
            Error;
        {'DOWN', Mon, process, Owner, _Why} ->
            {error, not_loaded}
    end.

-doc """
Give up an image whose pages could not be built: the claim and the charge go
back now, and the owner ends.
""".
-spec abandon(pid()) -> ok.
abandon(Owner) ->
    Mon = erlang:monitor(process, Owner),
    %% The flag is cleared by the owner before it gives anything back, so no
    %% restore is admitted while the claim and the charge are going.
    Owner ! abandon,
    receive {'DOWN', Mon, process, Owner, _} -> ok end.

init(Caller, Ref, Handle, Bytes, FirstHolder) ->
    case wasm_module_cache:claim_for(Handle, self()) of
        {error, not_loaded} ->
            Caller ! {Ref, {error, not_loaded}};
        ok ->
            Id = make_ref(),
            Mon = erlang:monitor(process, FirstHolder),
            Live = atomics:new(1, []),
            ok = atomics:put(Live, 1, 1),
            case reserve(Bytes, Id, Live) of
                {error, _} = E ->
                    ok = wasm_module_cache:unclaim_for(Handle, self()),
                    Caller ! {Ref, E};
                {ok, Img} ->
                    Caller ! {Ref, {ok, Img, Live}},
                    loop({Handle, Img, Id, Live}, Bytes, #{FirstHolder => Mon})
            end
    end.

%% A counter left by an older build fails closed rather than metering against a
%% value that may already be wrong, until the node is restarted.
reserve(Bytes, Id, Live) ->
    case counter_state() of
        {trusted, _Ref} ->
            wasm_keeper:image_reserve(Bytes, self(), Id, Live);
        legacy ->
            {error, #{class => invalid, kind => snapshot_counter_untrusted,
                      msg => ~"the snapshot budget predates this version and is untrusted; restart the node",
                      ctx => #{}}};
        missing ->
            {error, #{class => invalid, kind => snapshot_counter_uninitialised,
                      msg => ~"the snapshot budget counter is not initialised",
                      ctx => #{}}}
    end.

-doc """
Add a holder.

Holding a copied term is not ownership: the term crosses a message send for
free, and an image whose holders are whoever happens to have a copy has no
lifetime at all.
""".
-spec acquire(pid(), pid()) -> ok | gone.
acquire(Owner, Holder) -> ask(Owner, {acquire, Holder}).

-doc """
Add a holder within `Timeout` milliseconds, or answer `gone`.

The reply comes to an alias, so one that arrives after the caller gave up is
dropped rather than left in its mailbox, and a hold the owner granted after
that is given back. A worker passes the time left before its own deadline, so
a stalled owner delays only the workers asking it.
""".
-spec acquire(pid(), pid(), timeout()) -> ok | gone.
acquire(Owner, Holder, Timeout) ->
    Alias = erlang:monitor(process, Owner, [{alias, demonitor}]),
    Owner ! {{acquire, Holder}, Alias, Alias},
    receive
        {Alias, ok} ->
            erlang:demonitor(Alias, [flush]),
            ok;
        {'DOWN', Alias, process, Owner, _} ->
            gone
    after Timeout ->
        erlang:demonitor(Alias, [flush]),
        receive
            {Alias, ok} -> ok
        after 0 ->
            %% Sent after the acquire, so it is read after it: a hold granted
            %% to a caller that no longer waits for it does not outlive this
            %% call.
            ok = release(Owner, Holder),
            gone
        end
    end.

-doc "Drop a holder. Never blocks, and has one result.".
-spec release(pid(), pid()) -> ok.
release(Owner, Holder) -> Owner ! {release, Holder}, ok.

-doc "How many processes still hold this image, or `gone`.".
-spec holders(undefined | pid()) -> non_neg_integer() | gone.
%% An image with no owner has nothing holding it, which is the same answer as
%% one whose owner has gone. Reached by a snapshot read from a file before
%% anything attached an owner, and answering rather than raising is the rule
%% this runtime keeps everywhere else.
holders(undefined) -> gone;
holders(Owner) -> ask(Owner, holders).

ask(Owner, Msg) ->
    Ref = make_ref(),
    Mon = erlang:monitor(process, Owner),
    Owner ! {Msg, self(), Ref},
    receive
        {Ref, Reply} ->
            erlang:demonitor(Mon, [flush]),
            Reply;
        {'DOWN', Mon, process, Owner, _} ->
            gone
    after ?ASK_TIMEOUT ->
        erlang:demonitor(Mon, [flush]),
        gone
    end.

loop(Handle, Bytes, Holders) ->
    receive
        {{acquire, Pid}, From, Ref} ->
            From ! {Ref, ok},
            case maps:is_key(Pid, Holders) of
                true  -> loop(Handle, Bytes, Holders);
                false -> Mon = erlang:monitor(process, Pid),
                         loop(Handle, Bytes, Holders#{Pid => Mon})
            end;
        {holders, From, Ref} ->
            From ! {Ref, maps:size(Holders)},
            loop(Handle, Bytes, Holders);
        {release, Pid} ->
            drop(Handle, Bytes, Holders, Pid);
        abandon ->
            {Mod, Img, Id, Live} = Handle,
            ok = atomics:put(Live, 1, 0),
            ok = wasm_module_cache:unclaim_for(Mod, self()),
            ok = wasm_keeper:release(Img, {snapshot, Id});
        {'DOWN', _Mon, process, Pid, _Why} ->
            drop(Handle, Bytes, Holders, Pid)
    end.

drop(Handle, Bytes, Holders, Pid) ->
    case maps:take(Pid, Holders) of
        error ->
            loop(Handle, Bytes, Holders);
        {Mon, Rest} when map_size(Rest) > 0 ->
            _ = erlang:demonitor(Mon, [flush]),
            loop(Handle, Bytes, Rest);
        {Mon, _None} ->
            _ = erlang:demonitor(Mon, [flush]),
            %% The claim would go when this process exits anyway; doing it here
            %% means the claim and the charge are given back together rather
            %% than one of them whenever the cache notices.
            %% **The flag first**, before anything is given back, so a restore
            %% that reads it is refused rather than racing the claim. The
            %% keeper erases the image's publication when it sees the release
            %% below, which keeps every put and erase in one process.
            {Mod, Img, Id, Live} = Handle,
            ok = atomics:put(Live, 1, 0),
            ok = wasm_module_cache:unclaim_for(Mod, self()),
            ok = wasm_keeper:release(Img, {snapshot, Id}),
            ok
    end.

%%% --------------------------------------------------------------- budget ---
%%
%% Node-wide and **separate from `max_memory_pages`**, which bounds an instance
%% and not the images beside it. `infinity` by default, and that means
%% unbounded rather than off: the feature is off because nothing declares
%% snapshots, and conflating the two would let a host think it had a ceiling it
%% does not have.

-doc "Bytes currently charged to images across the node.".
-spec charged() -> non_neg_integer().
charged() ->
    case counter_state() of
        {trusted, Ref} -> max(0, atomics:get(Ref, 1));
        %% An untrusted or absent counter reports zero rather than raise: this
        %% is diagnostics, and its spec stays `non_neg_integer()'.
        _              -> 0
    end.

counter_state() ->
    case persistent_term:get(?SNAPSHOT_BUDGET_KEY, undefined) of
        {snapshot_counter, ?SNAPSHOT_BUDGET_VERSION, Ref} -> {trusted, Ref};
        undefined                                         -> missing;
        _Legacy                                           -> legacy
    end.
