-module(wasm_snapshot_registry).
-moduledoc """
Which loaded image the workers on a node share, per store key, and which
worker is loading one.

A script worker used to load its own copy of its image: fifty workers on one
file held fifty images and charged the snapshot budget fifty times, and two
workers starting together on a missing image both captured it. Workers with
the same store key now share one **generation**, one load or capture of the
image, held through its owner. This process is how a starting worker finds it.

```erlang
case wasm_snapshot_registry:acquire(Key, Deadline) of
    {ok, Generation, Owner} -> hold_it;
    {load, Token}           -> load_it_and_report;
    retry                   -> ask_again;
    timeout                 -> give_up;
    unavailable             -> load_a_private_copy
end.
```

Per store key it remembers one of two things:

- **loaded**: the generation and its owner, monitored. Not the image itself,
  so it never keeps a retired image's memory alive. The image is read from its
  publication, which only `wasm_keeper` puts and erases.
- **loading**: the one worker allowed to load or capture, with a fresh token,
  and the workers parked until it finishes, each with its own deadline.

## What it never does

It never calls an owner, so a stalled owner delays only the workers asking
it, each within its own deadline. A worker takes its hold itself, with
`wasm_snapshot_owner:acquire/3`. It never calls `wasm`, so it adds no cycle to
the module graph.

## Reports are checked by token

`loaded/5` and `failed/2` are accepted only from the current loader's token,
and `loaded/5` only for a generation that is published. After a restart of
this process every token is new, so a loader from before it cannot overwrite a
newer loader or drop its waiters. A refused loader asks again.

A restart loses only who loads what. Running workers keep their generations,
new workers load a new one, and each old generation ends through the keeper
when its last holder stops.
""".
-behaviour(gen_server).

-export([start_link/0, acquire/2, acquire/3, loaded/5, failed/2, loaded/1,
         image/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("wasm_snapshot.hrl").

-define(SERVER, ?MODULE).

-doc "An absolute `erlang:monotonic_time(millisecond)`, or `infinity`.".
-type deadline() :: integer() | infinity.

-type acquired() :: {ok, reference(), pid()} | {load, reference()} | retry
                  | timeout | unavailable.

-export_type([deadline/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "`acquire/3` with no generation to avoid.".
-spec acquire(term(), deadline()) -> acquired().
acquire(Key, Deadline) -> acquire(Key, Deadline, none).

-doc """
The generation loaded under `Key`, or the right to load one.

- `{ok, Generation, Owner}`: take a hold with
  `wasm_snapshot_owner:acquire/3`, then read the publication.
- `{load, Token}`: you are the loader; report with `loaded/5` or `failed/2`.
- `retry`: the loader you were parked behind failed; ask again.
- `timeout`: `Deadline` passed first.
- `unavailable`: no registry runs; load a copy of your own.

A caller parked behind a loader waits here until it reports. `Stale` names a
generation the caller could not hold: an entry naming it is dropped rather
than answered again.
""".
-spec acquire(term(), deadline(), reference() | none) -> acquired().
acquire(Key, Deadline, Stale) ->
    case left(Deadline) of
        0 -> timeout;
        Left -> ask({acquire, Key, Deadline, Stale}, Left)
    end.

-doc """
Report the generation the loader for `Key` holds and published. `refused`
when `Token` is not the current loader's, or the generation is not published;
`retry` when the registry died during the call.
""".
-spec loaded(term(), reference(), reference(), pid(), deadline()) ->
          ok | refused | retry | timeout | unavailable.
loaded(Key, Token, Generation, Owner, Deadline) ->
    case left(Deadline) of
        0 -> timeout;
        Left -> ask({loaded, Key, Token, Generation, Owner}, Left)
    end.

-doc "Report that the load under `Token` failed. A cast: it never blocks.".
-spec failed(term(), reference()) -> ok.
failed(Key, Token) -> gen_server:cast(?SERVER, {failed, Key, Token}).

-doc """
The published image of `Generation`, or `undefined` once it has ended. Read in
the caller, and a literal: sending it or capturing it in a closure copies
nothing.
""".
-spec image(reference()) -> term().
image(Generation) -> persistent_term:get(?SNAPSHOT_PUB(Generation), undefined).

-doc "What is known under `Key`, for tests and diagnostics.".
-spec loaded(term()) -> none | loading | {reference(), pid()}.
loaded(Key) ->
    case ask({loaded, Key}, 5_000) of
        Known when is_tuple(Known); Known =:= loading -> Known;
        _ -> none
    end.

%% Nothing raises: a registry that is not running is `unavailable', one that
%% died in the call is asked again, and a reply that comes after the time ran
%% out is dropped, since a call with a finite timeout waits on an alias.
ask(Req, Timeout) ->
    try gen_server:call(?SERVER, Req, Timeout)
    catch
        exit:{timeout, _} -> timeout;
        exit:{noproc, _}  -> unavailable;
        exit:_            -> retry
    end.

left(infinity) -> infinity;
left(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

expired(infinity) -> false;
expired(Deadline) -> erlang:monotonic_time(millisecond) >= Deadline.

%%% ------------------------------------------------------------ callbacks ---

%% keys :: #{Key => {loaded, G, Owner, Mon}
%%                | {loading, Loader, Token, Mon, [{From, Deadline, Mon}]}}
%% mons :: #{Mon => {owner, Key, G} | {loader, Key, Token} | {waiter, Key}}
init([]) ->
    {ok, #{keys => #{}, mons => #{}}}.

handle_call({acquire, Key, Deadline, Stale}, {Pid, _} = From,
            #{keys := Keys} = S) ->
    case maps:find(Key, Keys) of
        {ok, {loaded, G, Owner, _Mon}} when G =/= Stale ->
            case published(G) of
                true  -> {reply, {ok, G, Owner}, S};
                false -> become_loader(Key, Pid, forget(Key, S))
            end;
        {ok, {loaded, _G, _Owner, _Mon}} ->
            become_loader(Key, Pid, forget(Key, S));
        {ok, {loading, L, T, LMon, Waiters}} ->
            Mon = erlang:monitor(process, Pid),
            Keys1 = Keys#{Key := {loading, L, T, LMon,
                                  Waiters ++ [{From, Deadline, Mon}]}},
            {noreply, watch(Mon, {waiter, Key}, S#{keys := Keys1})};
        error ->
            become_loader(Key, Pid, S)
    end;

handle_call({loaded, Key, Token, G, Owner}, _From, #{keys := Keys} = S) ->
    case Keys of
        #{Key := {loading, _L, Token, _LMon, _Ws}} ->
            case published(G) of
                true ->
                    {reply, ok, settle(Key, {ok, G, Owner}, S)};
                false ->
                    %% The generation ended between its publication and this
                    %% report. The loader asks again, so it must not find
                    %% itself still loading.
                    {reply, refused, settle(Key, retry, S)}
            end;
        _ ->
            {reply, refused, S}
    end;

handle_call({loaded, Key}, _From, #{keys := Keys} = S) ->
    {reply, case maps:find(Key, Keys) of
                {ok, {loaded, G, Owner, _}} -> {G, Owner};
                {ok, {loading, _, _, _, _}} -> loading;
                error -> none
            end, S};

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({failed, Key, Token}, #{keys := Keys} = S) ->
    case Keys of
        #{Key := {loading, _L, Token, _LMon, _Ws}} ->
            {noreply, settle(Key, retry, S)};
        _ ->
            {noreply, S}
    end;
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _Pid, _Why}, #{mons := Mons} = S) ->
    case maps:take(Mon, Mons) of
        error ->
            {noreply, S};
        {What, Rest} ->
            {noreply, down(What, Mon, S#{mons := Rest})}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% An owner that exits drops the entry only if the entry still names its
%% generation: a newer one may have been loaded under the same key since.
down({owner, Key, G}, _Mon, #{keys := Keys} = S) ->
    case Keys of
        #{Key := {loaded, G, _, _}} -> S#{keys := maps:remove(Key, Keys)};
        _ -> S
    end;
down({loader, Key, Token}, _Mon, #{keys := Keys} = S) ->
    case Keys of
        #{Key := {loading, _, Token, _, _}} -> settle(Key, retry, S);
        _ -> S
    end;
down({waiter, Key}, Mon, #{keys := Keys} = S) ->
    case Keys of
        #{Key := {loading, L, T, LMon, Ws}} ->
            Ws1 = [W || {_, _, M} = W <- Ws, M =/= Mon],
            S#{keys := Keys#{Key := {loading, L, T, LMon, Ws1}}};
        _ ->
            S
    end.

become_loader(Key, Pid, #{keys := Keys} = S) ->
    Token = make_ref(),
    Mon = erlang:monitor(process, Pid),
    S1 = S#{keys := Keys#{Key => {loading, Pid, Token, Mon, []}}},
    {reply, {load, Token}, watch(Mon, {loader, Key, Token}, S1)}.

%% The load under `Key' ended. Every waiter still inside its deadline gets the
%% answer, and the expired ones are dropped: their callers stopped waiting.
settle(Key, Answer, #{keys := Keys} = S) ->
    {loading, _L, _T, LMon, Ws} = maps:get(Key, Keys),
    S1 = unwatch(LMon, S),
    S2 = lists:foldl(fun({From, Deadline, Mon}, Acc) ->
                             _ = expired(Deadline)
                                 orelse gen_server:reply(From, Answer),
                             unwatch(Mon, Acc)
                     end, S1, Ws),
    #{keys := Keys2} = S2,
    case Answer of
        {ok, G, Owner} ->
            Mon = erlang:monitor(process, Owner),
            watch(Mon, {owner, Key, G},
                  S2#{keys := Keys2#{Key := {loaded, G, Owner, Mon}}});
        retry ->
            S2#{keys := maps:remove(Key, Keys2)}
    end.

forget(Key, #{keys := Keys} = S) ->
    {loaded, _G, _Owner, Mon} = maps:get(Key, Keys),
    unwatch(Mon, S#{keys := maps:remove(Key, Keys)}).

watch(Mon, What, #{mons := Mons} = S) -> S#{mons := Mons#{Mon => What}}.

unwatch(Mon, #{mons := Mons} = S) ->
    erlang:demonitor(Mon, [flush]),
    S#{mons := maps:remove(Mon, Mons)}.

%% Publication is the keeper's proof that the generation belongs to its
%% current state and is still restorable: it erases it when the owner goes.
published(G) -> image(G) =/= undefined.
