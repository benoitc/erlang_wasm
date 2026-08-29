-module(wasm_module_cache).
-moduledoc """
Compiled modules, cached node-wide and keyed by content hash.

You reach this through `wasm:load/1` and `wasm:load_file/1`. Decoding and
validating is the expensive part of the pipeline, about 20 ms for a 100 KB Rust
binary against 15 us to instantiate one, and a plugin host or a
request-per-instance service compiles a small stable set of modules and
instantiates them constantly. So the compile belongs behind a cache and the
instantiate does not.

## Why `persistent_term`

A compiled module is immutable and read on every instantiation, which is
exactly what `persistent_term` is for: reads do not copy, however large the
term. ETS would copy the whole intermediate representation into the reading
process every time, and that IR is megabytes for a real module.

The cost is on the other side: every `put` and `erase` triggers a global scan.
That is fine here precisely because loading is rare and instantiating is not,
but it does mean you should not call `load/1` in a loop, and it makes anyone who
can drive repeated load and unload cycles a denial of service. Hence the rate
limit and the resident cap below, enforced here rather than left to you to
remember.

## Identity is the content hash

Load the same bytes from two places and you get the same handle and share one
compiled artefact, with no coordination. It also means either of you can call
`unload/1` safely: the module stays resident until the last holder drops it.
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([load/1, load/2, unload/1, get/1, resident/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("wasm.hrl").

-define(SERVER, ?MODULE).
-define(PT_KEY(Hash), {wasm_module, Hash}).

%% Node-wide ceilings. Both exist to bound the `persistent_term` global scans
%% that loading and unloading trigger.
-define(DEFAULT_MAX_RESIDENT, 256).
-define(DEFAULT_MAX_LOADS_PER_SECOND, 50).

%% Every call here is a map update; nothing expensive happens inside the
%% server any more, so a timeout means the node is in trouble rather than that
%% somebody is loading something large.
-define(CALL_TIMEOUT, 30000).

-doc "An opaque handle to a cached module.".
-nominal handle() :: {wasm_module, binary()}.
-export_type([handle/0]).

-record(state, {
    %% hash => #{holders := non_neg_integer(), size := non_neg_integer()}
    resident = #{} :: map(),
    %% hash => {pid(), [gen_server:from()]}: who is compiling it, and who is
    %% waiting for them to finish. A second caller for the same bytes waits
    %% here rather than compiling them again, which is how it keeps its claim.
    compiling = #{} :: map(),
    %% pid => #{hash => count}: what each process holds. A holder that dies
    %% without unloading gives its claims back, which is why they are recorded
    %% per process rather than only as a total.
    claims = #{} :: map(),
    monitors = #{} :: map(),
    window_start = 0 :: integer(),
    window_count = 0 :: non_neg_integer(),
    max_resident :: pos_integer(),
    max_rate :: pos_integer()
}).

%%% ----------------------------------------------------------------- api ---

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Decode, validate and cache a module, returning a handle.

Load the same bytes twice and the second call is cheap: it finds the compiled
artefact already resident and only bumps its holder count.
""".
-spec load(binary()) -> {ok, handle()} | {error, term()}.
load(Binary) -> load(Binary, #{}).

-spec load(binary(), map()) -> {ok, handle()} | {error, term()}.
load(Binary, _Opts) when is_binary(Binary) ->
    Hash = crypto:hash(sha256, Binary),
    case call({acquire, Hash}) of
        {ok, already_resident} ->
            {ok, {wasm_module, Hash}};
        {ok, compile_it} ->
            %% Compiling outside the server keeps a large module from blocking
            %% every other loader for the duration.
            %% The hash is already computed, so hand it over as the module's
            %% identity rather than letting it be hashed again or given a
            %% reference. Two loads of the same bytes then agree, which is what
            %% lets anything derived from a module be shared between them.
            case wasm:compile(Binary, #{identity => {sha256, Hash}}) of
                {ok, Module} -> publish(Hash, Module);
                {error, _} = Error ->
                    _ = call({abandon, Hash, Error}),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Published from here rather than from inside the server, so a module term
%% that is megabytes never enters the server's mailbox and the global scan
%% `persistent_term:put' triggers is paid by the loader instead of by everybody
%% waiting behind it.
publish(Hash, Module) ->
    persistent_term:put(?PT_KEY(Hash), Module),
    %% `size_shared/1', not `size/1'. They answer the same question, and on a
    %% real 1.8 MB module `size/1' measured 24 s against 34 ms because it walks
    %% shared subterms once per reference.
    Size = erts_debug:size_shared(Module) * erlang:system_info(wordsize),
    case call({stored, Hash, Size}) of
        ok -> {ok, {wasm_module, Hash}};
        {error, _} = Error ->
            persistent_term:erase(?PT_KEY(Hash)),
            Error
    end.

%% Nothing this library exposes may raise, including when the server is
%% overloaded or absent, so a `gen_server' exit becomes the same kind of value
%% every other failure here is.
call(Request) ->
    try gen_server:call(?SERVER, Request, ?CALL_TIMEOUT)
    catch
        exit:{timeout, _} ->
            ok = gave_up(Request),
            {error, #{class => link, kind => cache_timeout,
                      msg => <<"module cache did not answer in time">>,
                      ctx => #{request => element(1, Request),
                               timeout_ms => ?CALL_TIMEOUT}}};
        exit:{noproc, _} ->
            {error, #{class => link, kind => cache_unavailable,
                      msg => <<"the wasm application is not running">>,
                      ctx => #{request => element(1, Request)}}};
        exit:Reason ->
            {error, #{class => link, kind => cache_unavailable,
                      msg => <<"module cache is unavailable">>,
                      ctx => #{request => element(1, Request),
                               reason => Reason}}}
    end.

%% Tell the server this caller is no longer waiting, so it is not given a claim
%% it has no handle for and will never release. Only `acquire' can leave one
%% behind, and a failure here leaves exactly the behaviour that was there before
%% the message existed, so it is not worth raising over.
gave_up({acquire, Hash}) ->
    try gen_server:call(?SERVER, {gave_up, Hash}, 5000) of
        _ -> ok
    catch exit:_ -> ok
    end;
gave_up(_Other) ->
    ok.

-doc """
Drop your claim. The module stays resident until the last holder goes.

Claims are per process: this drops one held by the calling process, and a
process that dies without calling it has its claims dropped for it.
""".
-spec unload(handle()) -> ok.
unload({wasm_module, Hash}) ->
    _ = call({release, Hash}),
    ok.

-doc """
Fetch a cached module. It reads without copying, so you can call it on every
instantiation.
""".
-spec get(handle()) -> {ok, #module{}} | {error, not_loaded}.
get({wasm_module, Hash}) ->
    case persistent_term:get(?PT_KEY(Hash), undefined) of
        undefined -> {error, not_loaded};
        Module -> {ok, Module}
    end.

-spec resident() -> non_neg_integer().
resident() -> gen_server:call(?SERVER, resident).

-spec stats() -> map().
stats() -> gen_server:call(?SERVER, stats).

%%% ------------------------------------------------------------ callbacks ---

init([]) ->
    ok = purge(),
    {ok, #state{max_resident = application:get_env(wasm, max_resident_modules,
                                                   ?DEFAULT_MAX_RESIDENT),
                max_rate = application:get_env(wasm, max_module_loads_per_second,
                                               ?DEFAULT_MAX_LOADS_PER_SECOND)}}.

%% Everything a previous cache published, which this one has no record of.
%%
%% The state is a map of what is resident and it starts empty, but
%% `persistent_term' is node-wide and outlives the process. So after a restart
%% every module ever loaded was still published, with nothing tracking it:
%% `get/1' on an old handle succeeded, no claim was ever counted against it,
%% and no eviction would ever reach it. Modules are megabytes each, so a
%% restart loop held the node's memory for good while the cache believed it
%% held nothing.
%%
%% Handles that named those modules answer `not_loaded' now, which is a value
%% callers already have to handle and is what a cache that lost its state
%% honestly means.
%%
%% Reading the whole store does not copy the terms; that is the property the
%% cache is built on.
purge() ->
    _ = [persistent_term:erase(K)
         || {{wasm_module, _} = K, _} <- persistent_term:get()],
    ok.

handle_call({acquire, Hash}, {Pid, _} = From, State) ->
    case maps:find(Hash, State#state.resident) of
        {ok, _Entry} ->
            {reply, {ok, already_resident}, add_claim(Pid, Hash, State)};
        error ->
            acquire_missing(Hash, From, State)
    end;

%% A waiter that gave up.
%%
%% `stored` claims for everybody in the waiting list that is still alive, and a
%% caller whose `gen_server:call/3` timed out is very much alive: it got an
%% error, has no handle, and will never release, so its claim pinned the module
%% for the life of the node. Being told is the only way the server can know, and
%% because it is a call into the same serialised process there are exactly two
%% orders and both end correctly: before `stored`, this takes the caller out of
%% the waiting list so no claim is made; after it, the claim is dropped.
%%
%% `drop_claim/3` is already a no-op for a process that claimed nothing, which
%% is what makes the first order safe.
handle_call({gave_up, Hash}, {Pid, _}, State) ->
    Compiling =
        case maps:find(Hash, State#state.compiling) of
            {ok, {Compiler, Waiting}} ->
                maps:put(Hash, {Compiler, [W || {P, _} = W <- Waiting, P =/= Pid]},
                         State#state.compiling);
            error ->
                State#state.compiling
        end,
    {reply, ok, drop_claim(Pid, Hash, State#state{compiling = Compiling})};

handle_call({stored, Hash, Size}, {Pid, _}, State0) ->
    {_Compiler, Waiting} = maps:get(Hash, State0#state.compiling, {Pid, []}),
    State1 = State0#state{
               compiling = maps:remove(Hash, State0#state.compiling),
               resident = maps:put(Hash, #{holders => 0, size => Size},
                                   State0#state.resident)},
    %% One claim for whoever compiled it and one for everybody who waited,
    %% because every one of them asked for the module and expects a handle
    %% that stays valid until they drop it.
    %%
    %% Except the ones that are gone. A waiter can die at any point between
    %% asking and this reply, and its `DOWN' has already been handled by then:
    %% claiming for it afterwards puts back a claim nothing will ever remove,
    %% and the module stays resident for the life of the node. Anything that
    %% dies *after* this check is covered, because claiming monitors it.
    State2 = lists:foldl(fun({W, _}, S) -> claim_if_alive(W, Hash, S) end,
                         claim_if_alive(Pid, Hash, State1),
                         Waiting),
    _ = [gen_server:reply(W, {ok, already_resident}) || W <- Waiting],
    {reply, ok, State2};

handle_call({abandon, Hash, Error}, {Pid, _}, State) ->
    %% Everybody waiting on this compile asked for the same bytes, so they get
    %% the same answer rather than being left to time out.
    {_, Waiting} = maps:get(Hash, State#state.compiling, {Pid, []}),
    _ = [gen_server:reply(W, Error) || W <- Waiting],
    {reply, ok, unwatch(Pid, State#state{
                          compiling = maps:remove(Hash, State#state.compiling)})};

handle_call({release, Hash}, {Pid, _}, State) ->
    {reply, ok, drop_claim(Pid, Hash, State)};

handle_call(resident, _From, State) ->
    {reply, maps:size(State#state.resident), State};
handle_call(stats, _From, State) ->
    Bytes = lists:sum([maps:get(size, E) || E <- maps:values(State#state.resident)]),
    {reply, #{resident => maps:size(State#state.resident),
              bytes => Bytes,
              max_resident => State#state.max_resident,
              max_loads_per_second => State#state.max_rate}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% A holder that exits gives its claims back. Without this a process that
%% loaded and then died kept the module resident for the life of the node, and
%% enough of them filled the resident cap until `load/1' refused everything.
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State0) ->
    State1 = fail_compiles(Pid, State0),
    Held = maps:get(Pid, State1#state.claims, #{}),
    State2 = State1#state{claims = maps:remove(Pid, State1#state.claims),
                          monitors = maps:remove(Pid, State1#state.monitors)},
    {noreply, maps:fold(fun(Hash, N, S) -> drop_holders(Hash, N, S) end,
                        State2, Held)};
handle_info(_Info, State) -> {noreply, State}.

%%% ---------------------------------------------------------------- claims ---

acquire_missing(Hash, {Pid, _} = From, State) ->
    case maps:find(Hash, State#state.compiling) of
        {ok, {Compiler, Waiting}} ->
            %% Somebody is already compiling these bytes. Waiting for them
            %% costs one reply and keeps both claims; compiling it too would
            %% mean the second `stored' overwrote the first one's.
            Compiling = maps:put(Hash, {Compiler, [From | Waiting]},
                                 State#state.compiling),
            {noreply, State#state{compiling = Compiling}};
        error ->
            case admit(State) of
                {ok, State1} ->
                    Compiling = maps:put(Hash, {Pid, []}, State1#state.compiling),
                    {reply, {ok, compile_it},
                     watch(Pid, State1#state{compiling = Compiling})};
                {error, _} = Error ->
                    {reply, Error, State}
            end
    end.

claim_if_alive({Pid, _Tag}, Hash, State) -> claim_if_alive(Pid, Hash, State);
claim_if_alive(Pid, Hash, State) ->
    case is_process_alive(Pid) of
        true -> add_claim(Pid, Hash, State);
        false -> State
    end.

add_claim(Pid, Hash, State) ->
    Mine = maps:get(Pid, State#state.claims, #{}),
    Held = maps:get(Hash, Mine, 0),
    Resident = maps:update_with(
                 Hash, fun(#{holders := N} = E) -> E#{holders => N + 1} end,
                 State#state.resident),
    watch(Pid, State#state{
                 resident = Resident,
                 claims = maps:put(Pid, maps:put(Hash, Held + 1, Mine),
                                   State#state.claims)}).

drop_claim(Pid, Hash, State) ->
    Mine = maps:get(Pid, State#state.claims, #{}),
    case maps:get(Hash, Mine, 0) of
        0 ->
            %% Releasing something this process never claimed. Not an error,
            %% and deliberately not a decrement either: taking somebody else's
            %% claim away is how a live holder loses its module.
            State;
        1 ->
            drop_holders(Hash, 1, forget(Pid, maps:remove(Hash, Mine), State));
        N ->
            drop_holders(Hash, 1, forget(Pid, maps:put(Hash, N - 1, Mine), State))
    end.

forget(Pid, Mine, State) when map_size(Mine) =:= 0 ->
    unwatch(Pid, State#state{claims = maps:remove(Pid, State#state.claims)});
forget(Pid, Mine, State) ->
    State#state{claims = maps:put(Pid, Mine, State#state.claims)}.

drop_holders(Hash, N, State) ->
    case maps:find(Hash, State#state.resident) of
        {ok, #{holders := H}} when H =< N ->
            persistent_term:erase(?PT_KEY(Hash)),
            State#state{resident = maps:remove(Hash, State#state.resident)};
        {ok, #{holders := H} = Entry} ->
            State#state{resident = maps:put(Hash, Entry#{holders => H - N},
                                            State#state.resident)};
        error ->
            State
    end.

%% A compiler that dies leaves everybody waiting on it with nothing to wait
%% for, so they are told rather than left to time out.
fail_compiles(Pid, State) ->
    Dead = [{H, W} || {H, {C, W}} <- maps:to_list(State#state.compiling),
                      C =:= Pid],
    Error = {error, #{class => link, kind => compile_abandoned,
                      msg => <<"the process compiling this module exited">>,
                      ctx => #{}}},
    _ = [gen_server:reply(W, Error) || {_, Ws} <- Dead, W <- Ws],
    State#state{compiling = maps:without([H || {H, _} <- Dead],
                                         State#state.compiling)}.

%% One monitor per process, however many modules it holds.
watch(Pid, #state{monitors = Ms} = State) ->
    case maps:is_key(Pid, Ms) of
        true -> State;
        false -> State#state{monitors = maps:put(Pid, erlang:monitor(process, Pid), Ms)}
    end.

unwatch(Pid, #state{monitors = Ms, claims = Claims, compiling = Compiling} = State) ->
    case maps:is_key(Pid, Claims) orelse compiling_for(Pid, Compiling) of
        true -> State;
        false ->
            case maps:find(Pid, Ms) of
                {ok, Ref} ->
                    erlang:demonitor(Ref, [flush]),
                    State#state{monitors = maps:remove(Pid, Ms)};
                error -> State
            end
    end.

compiling_for(Pid, Compiling) ->
    lists:any(fun({C, _}) -> C =:= Pid end, maps:values(Compiling)).

%%% --------------------------------------------------------------- limits ---

%% Both ceilings guard the same thing: `persistent_term` writes trigger a
%% node-wide scan, so an attacker able to drive load and unload cycles could
%% otherwise spend the whole node's time scanning.
admit(State) ->
    %% Modules being compiled count: they are about to be resident, and without
    %% counting them enough concurrent first loads walk straight past the cap.
    InUse = maps:size(State#state.resident) + maps:size(State#state.compiling),
    case InUse >= State#state.max_resident of
        true -> {error, {too_many_modules, State#state.max_resident}};
        false -> rate_limit(State)
    end.

rate_limit(State) ->
    Now = erlang:monotonic_time(second),
    case Now =:= State#state.window_start of
        false ->
            {ok, State#state{window_start = Now, window_count = 1}};
        true when State#state.window_count < State#state.max_rate ->
            {ok, State#state{window_count = State#state.window_count + 1}};
        true ->
            {error, {load_rate_exceeded, State#state.max_rate}}
    end.
