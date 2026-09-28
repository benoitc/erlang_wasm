%% @doc `fake_reactor_adapter', with a `defaults/0' asking for a runner floor.
%%
%% The one thing it adds is the optional callback, so a case can tell the
%% worker reading an adapter's defaults from the worker it always was.
%% `fake_reactor_adapter' has no `defaults/0' and stays the control.
-module(fake_floor_adapter).
-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1, defaults/0]).

defaults() ->
    #{runner_min_heap_words => 200_000}.

artifact(Opts)                -> fake_reactor_adapter:artifact(Opts).
requirements(Request, A)      -> fake_reactor_adapter:requirements(Request, A).
prepare(Request, A, Env)      -> fake_reactor_adapter:prepare(Request, A, Env).
decode(Result, State)         -> fake_reactor_adapter:decode(Result, State).
cleanup(State)                -> fake_reactor_adapter:cleanup(State).
capabilities(A)               -> fake_reactor_adapter:capabilities(A).
conformance_fixtures(A)       -> fake_reactor_adapter:conformance_fixtures(A).
classify(Result, State)       -> fake_reactor_adapter:classify(Result, State).
snapshot_capability(A)        -> fake_reactor_adapter:snapshot_capability(A).
