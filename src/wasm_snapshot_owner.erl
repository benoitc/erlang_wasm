-module(wasm_snapshot_owner).
-moduledoc """
One process per snapshot, holding what an Erlang term cannot hold for itself.

An image is a term and the BEAM will collect it, but a term cannot say "I am
gone", and two things have to be given back when it is: the image's claim on
its module, and its share of the node-wide byte budget. So each image gets a
process whose life matches its own, and whose only job is to know who still
wants it.

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

Not the keeper. The plan put this in `wasm_keeper`, on the grounds that it is
already the long-lived owner of every other snapshot resource. The keeper keeps
its state in ETS rows that a restart adopts, so a second concern there is real
surgery on the one process a node cannot do without, and the guarantee does not
need it: what an image needs is *a* lifetime matching its own.

It also makes invalidation fall out rather than be enforced. The claim is made
for this process, so it dies when this process does, and the cache is what
sees to that.
""".

-export([start/3, acquire/2, release/2, holders/1]).
-export([charge/1, refund/1, charged/0]).

-define(BUDGET_KEY, {?MODULE, charged}).
-define(ASK_TIMEOUT, 5_000).

-doc """
Start an owner holding `Handle` for `FirstHolder`, or say the module is gone.

The claim is taken here rather than by the caller, because a claim belongs to
the process that will give it back.
""".
-spec start(wasm_module_cache:handle(), non_neg_integer(), pid()) ->
          {ok, pid()} | {error, not_loaded}.
start(Handle, Bytes, FirstHolder) ->
    Self = self(),
    Ref = make_ref(),
    Owner = spawn(fun() ->
                      case wasm_module_cache:claim_for(Handle, self()) of
                          {error, not_loaded} ->
                              Self ! {Ref, {error, not_loaded}};
                          ok ->
                              Self ! {Ref, ok},
                              Mon = erlang:monitor(process, FirstHolder),
                              loop(Handle, Bytes, #{FirstHolder => Mon})
                      end
                  end),
    receive
        {Ref, ok}                 -> {ok, Owner};
        {Ref, {error, _} = Error} -> Error
    after ?ASK_TIMEOUT ->
        exit(Owner, kill),
        {error, not_loaded}
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
            ok = wasm_module_cache:unclaim_for(Handle, self()),
            _ = refund(Bytes),
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
charged() -> max(0, atomics:get(counter(), 1)).

-doc """
Charge an image, once, at capture.

A restore does **not** charge again: it takes the existing image, and the fresh
memories it builds are an instance's and go to ordinary instance accounting
where they belong. Charging per restore would make the budget mean something
different depending on how many restores were in flight.
""".
-spec charge(non_neg_integer()) -> ok | {error, wasm_error:error()}.
charge(Bytes) ->
    Limit = application:get_env(wasm, max_snapshot_bytes, infinity),
    Now = atomics:add_get(counter(), 1, Bytes),
    case Limit =:= infinity orelse Now =< Limit of
        true ->
            ok;
        false ->
            _ = refund(Bytes),
            {error, #{class => exhaustion, kind => snapshot_budget,
                      msg => ~"the node snapshot budget is exhausted",
                      ctx => #{limit => Limit, wanted => Bytes}}}
    end.

-spec refund(non_neg_integer()) -> integer().
refund(Bytes) -> atomics:sub_get(counter(), 1, Bytes).

counter() ->
    case persistent_term:get(?BUDGET_KEY, undefined) of
        undefined ->
            _ = persistent_term:put(?BUDGET_KEY, atomics:new(1, [])),
            persistent_term:get(?BUDGET_KEY);
        Ref ->
            Ref
    end.
