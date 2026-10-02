-module(wasm_snapshot_owner).
-moduledoc """
One process per snapshot, holding what an Erlang term cannot hold for itself.

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
""".

-export([start/4, acquire/2, release/2, holders/1]).
-export([charged/0]).

-include("wasm_snapshot_budget.hrl").

-define(ASK_TIMEOUT, 5_000).

-doc """
Start an owner holding `Handle` for `FirstHolder`, charge the image's `Bytes`,
and run `Build` in the owner with the image's keeper record, answering what it
built.

The claim is taken here rather than by the caller, because a claim belongs to
the process that will give it back. `Build` runs here for the same reason: an
image read from a file is charged before its pages exist, and a build that
fails, or an owner that dies building, gives the charge and the claim back by
this process exiting, whatever becomes of the caller.
""".
-spec start(wasm_module_cache:handle(), non_neg_integer(), pid(),
            fun((wasm_keeper:resource()) -> term())) ->
          {ok, pid(), term()} | {error, not_loaded | wasm_error:error()}.
start(Handle, Bytes, FirstHolder, Build) ->
    Self = self(),
    Ref = make_ref(),
    Owner = spawn(fun() -> init(Self, Ref, Handle, Bytes, FirstHolder, Build) end),
    Mon = erlang:monitor(process, Owner),
    receive
        {Ref, {ok, Built}} ->
            erlang:demonitor(Mon, [flush]),
            {ok, Owner, Built};
        {Ref, {error, _} = Error} ->
            erlang:demonitor(Mon, [flush]),
            Error;
        {'DOWN', Mon, process, Owner, Why} ->
            {error, #{class => malformed, kind => internal,
                      msg => ~"the image could not be built",
                      ctx => #{exception => Why}}}
    end.

init(Caller, Ref, Handle, Bytes, FirstHolder, Build) ->
    case wasm_module_cache:claim_for(Handle, self()) of
        {error, not_loaded} ->
            Caller ! {Ref, {error, not_loaded}};
        ok ->
            Id = make_ref(),
            case reserve(Bytes, Id) of
                {error, _} = E ->
                    ok = wasm_module_cache:unclaim_for(Handle, self()),
                    Caller ! {Ref, E};
                {ok, Img} ->
                    case wasm_error:capture(fun() -> {ok, Build(Img)} end) of
                        {ok, Built} ->
                            Mon = erlang:monitor(process, FirstHolder),
                            Caller ! {Ref, {ok, Built}},
                            loop({Handle, Img, Id}, Bytes,
                                 #{FirstHolder => Mon});
                        {error, _} = E ->
                            %% Exiting gives the charge back: the keeper sees
                            %% this process, the image's only holder, go.
                            ok = wasm_module_cache:unclaim_for(Handle, self()),
                            Caller ! {Ref, E}
                    end
            end
    end.

%% A counter left by an older build fails closed rather than metering against a
%% value that may already be wrong, until the node is restarted.
reserve(Bytes, Id) ->
    case counter_state() of
        {trusted, _Ref} ->
            wasm_keeper:image_reserve(Bytes, self(), Id);
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
            {Mod, Img, Id} = Handle,
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
