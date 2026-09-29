%% @doc `fake_reactor_adapter', with a `defaults/1' asking for a runner floor.
%%
%% The one thing it adds is the optional callback, so a case can tell the
%% worker reading an adapter's defaults from the worker it always was.
%% `fake_reactor_adapter' has no `defaults/1' and stays the control.
%%
%% The floor follows the tier the way `wasm_python:defaults/1' does, so the
%% kernel suite can hold the rule without a CPython start: 400,000 words when
%% the limits will run generated code, 200,000 otherwise. The two round to
%% different heap-size classes, 514,838 and 318,187.
-module(fake_floor_adapter).
-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1, defaults/1]).

defaults(Limits) ->
    case maps:get(compile, Limits, false) =:= true andalso
         maps:get(fuel, Limits, infinity) =:= infinity of
        true  -> #{runner_min_heap_words => 400_000};
        false -> #{runner_min_heap_words => 200_000}
    end.

artifact(Opts)                -> fake_reactor_adapter:artifact(Opts).
requirements(Request, A)      -> fake_reactor_adapter:requirements(Request, A).
prepare(Request, A, Env)      -> fake_reactor_adapter:prepare(Request, A, Env).
decode(Result, State)         -> fake_reactor_adapter:decode(Result, State).
cleanup(State)                -> fake_reactor_adapter:cleanup(State).
capabilities(A)               -> fake_reactor_adapter:capabilities(A).
conformance_fixtures(A)       -> fake_reactor_adapter:conformance_fixtures(A).
classify(Result, State)       -> fake_reactor_adapter:classify(Result, State).
snapshot_capability(A)        -> fake_reactor_adapter:snapshot_capability(A).
