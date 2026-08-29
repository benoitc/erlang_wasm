-module(wasm_worker).
-moduledoc """
A worker owning one WebAssembly instance, in the Cloudflare-Workers shape.

This is an example, not part of the library. Copy it, change it, or ignore it.
It exists because the controls a worker gives you are exactly the ones an
inline call cannot, and because getting them subtly wrong is easy.

It is also *tested*, by `wasm_worker_SUITE`, so the pattern documented here is
known to work rather than merely to look right.

## What the process buys

An inline `wasm:call/3` runs in the caller's process. That is the fast path and
it is the right answer for trusted code, but it means:

- a module looping forever hangs *you*, and cannot be killed without killing you
- there is no timeout to set, because the call is synchronous in your process
- `max_heap_size` protects nothing, because the allocation is on your heap
- two processes sharing the instance race, because both read-modify-write it

Owning the instance in a process fixes all four, for one message round trip
(measured: about 950 ns, against 11 KB of process overhead).

## Isolation policy

The central choice for a Workers-style system, and the one most likely to be
got wrong quietly:

- `fresh` destroys and re-creates the instance after every request, so no
  memory, global or table content survives it. This is the default, because
  "my worker leaked data between requests" is the failure the other option
  causes.
- `reuse` keeps the instance, which is faster but lets state persist. Correct
  only for modules that are stateless by construction, or that you trust.

`fresh` is affordable here: the module is compiled once and cached, so a reset
is one `destroy` plus one `instantiate`, roughly 15 us plus page allocation.

## Parallelism

Comes from more workers, never from concurrent calls into one instance. Run a
pool and check one out per request.
""".

-behaviour(gen_server).

-export([start_link/1, start_link/2, call/3, call/4, stop/1, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2, terminate/2]).

-record(state, {
    module,                        % cached module handle
    imports = #{} :: map(),
    limits = #{} :: map(),
    isolation = fresh :: fresh | reuse,
    instance,
    served = 0 :: non_neg_integer(),
    name :: term()
}).

%%% ------------------------------------------------------------------ api ---

-doc """
Start a worker over an already-loaded module.

`Opts` accepts `imports`, `limits`, `isolation` (`fresh` | `reuse`) and `name`.
""".
-spec start_link(wasm:module_()) -> {ok, pid()} | {error, term()}.
start_link(Module) -> start_link(Module, #{}).

-spec start_link(wasm:module_(), map()) -> {ok, pid()} | {error, term()}.
start_link(Module, Opts) ->
    gen_server:start_link(?MODULE, {Module, Opts}, []).

-doc """
Run one request.

The timeout is enforced on both sides: `gen_server:call` stops waiting, and the
worker is killed so the work actually stops. Giving up without killing would
leave a runaway module burning a scheduler with nobody watching.
""".
-spec call(pid(), binary(), [term()]) -> {ok, [term()]} | {error, term()}.
call(Pid, Function, Args) -> call(Pid, Function, Args, 5000).

-spec call(pid(), binary(), [term()], timeout()) -> {ok, [term()]} | {error, term()}.
call(Pid, Function, Args, Timeout) ->
    try
        gen_server:call(Pid, {run, Function, Args}, Timeout)
    catch
        exit:{timeout, _} ->
            exit(Pid, kill),
            {error, #{class => exhaustion, kind => timeout,
                      msg => ~"request timed out", ctx => #{timeout => Timeout}}};
        exit:{noproc, _} ->
            {error, #{class => link, kind => no_worker,
                      msg => ~"worker is gone", ctx => #{}}};
        exit:{Reason, _} ->
            {error, #{class => trap, kind => worker_died,
                      msg => ~"worker died", ctx => #{reason => Reason}}}
    end.

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

-spec info(pid()) -> {ok, map()}.
info(Pid) -> gen_server:call(Pid, info).

%%% ------------------------------------------------------------- callbacks ---

init({Module, Opts}) ->
    Limits = maps:get(limits, Opts, #{}),
    %% Bounds runaway *term* allocation: an enormous operand stack kills this
    %% worker rather than whoever called it. It does not see linear memory,
    %% which is off-heap and accounted by `wasm_engine`.
    case maps:get(max_heap_words, Limits, undefined) of
        undefined -> ok;
        Words -> process_flag(max_heap_size,
                              #{size => Words, kill => true, error_logger => true})
    end,
    %% Exits must be trapped or `terminate/2` never runs on a supervisor
    %% shutdown, and the instance's pages would only come back when the process
    %% died rather than when it was asked to stop.
    process_flag(trap_exit, true),
    Name = maps:get(name, Opts, undefined),
    %% Makes the worker identifiable in `observer`, `recon` and crash dumps
    %% instead of being an anonymous pid.
    proc_lib:set_label({wasm_worker, Name}),
    State = #state{module = Module,
                   imports = maps:get(imports, Opts, #{}),
                   limits = Limits,
                   isolation = maps:get(isolation, Opts, fresh),
                   name = Name},
    %% Instantiating in `handle_continue` keeps a large module from blocking
    %% the supervisor's start, and reports failure the same way as any other.
    {ok, State, {continue, instantiate}}.

handle_continue(instantiate, State) ->
    case new_instance(State) of
        {ok, Inst} -> {noreply, State#state{instance = Inst}};
        {error, Reason} -> {stop, {instantiate_failed, Reason}, State}
    end.

handle_call({run, _F, _A}, _From, #state{instance = undefined} = State) ->
    {reply, {error, #{class => link, kind => no_instance,
                      msg => ~"worker has no instance", ctx => #{}}}, State};
handle_call({run, Function, Args}, _From, State) ->
    Result = wasm:call(State#state.instance, Function, Args, State#state.limits),
    {reply, Result, recycle(State#state{served = State#state.served + 1})};
handle_call(info, _From, State) ->
    {reply, {ok, #{served => State#state.served,
                   isolation => State#state.isolation,
                   name => State#state.name}}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{instance = undefined}) -> ok;
terminate(_Reason, #state{instance = Inst}) -> wasm:destroy(Inst).

%%% ---------------------------------------------------------------- helpers ---

new_instance(#state{module = Module, imports = Imports, limits = Limits}) ->
    wasm:instantiate(Module, Imports, Limits).

%% Under `fresh`, the instance is replaced after every request, so nothing at
%% all carries over: not linear memory, not globals, not table contents.
recycle(#state{isolation = reuse} = State) ->
    State;
recycle(#state{isolation = fresh, instance = Old} = State) ->
    ok = wasm:destroy(Old),
    case new_instance(State) of
        {ok, Inst} -> State#state{instance = Inst};
        %% Leave the worker alive but instance-less: the next request gets a
        %% clear error rather than a crash loop, and a supervisor can decide.
        {error, _} -> State#state{instance = undefined}
    end.
