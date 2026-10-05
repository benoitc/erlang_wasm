-module(barrier_adapter).
-moduledoc """
Hold a worker request after its last guest call, with the instance alive.

Benchmark only. `densitybench workers` needs to sample node memory while every
worker has an instance that has served its request and not yet been
destroyed. That moment is inside the runner, between the last
`wasm:call/4` and the kernel's `wasm:destroy/1`, and the one callback that runs
there is `classify/2` (`wasm_script_worker:execute/3`). This wraps a stock
adapter, forwards every callback, and in `classify/2` sends `{ready, self()}`
to the harness and waits for `go` before forwarding.

    {ok, W} = wasm_script_worker:start_link(
                barrier_adapter,
                #{under => wasm_python, harness => self(),
                  path => "...", lib => "...", root => scratch}).

Modelled on `phasing_adapter`. The guest is unchanged, so are its mounts, its
preopens and its image: `snapshot_capability/1` is the stock adapter's own, so
the image key, and the filed image, are the ones the stock adapter would use.

**`defaults/1` is not forwarded**, because it is given the worker's limits and
not the artifact, so it cannot know which adapter it wraps. The harness passes
the stock adapter's `runner_min_heap_words` as a worker option instead, which
the kernel prefers over `defaults/1` in any case.

Every request waits, warm ones included: the harness answers `go` at once
when it is not measuring. A request whose `go` never comes is ended by the
worker's own deadline.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).

artifact(Opts) ->
    Under = maps:get(under, Opts),
    Harness = maps:get(harness, Opts),
    case Under:artifact(Opts) of
        {ok, Inner} ->
            {ok, #{under => Under, harness => Harness, inner => Inner}};
        {error, _} = E ->
            E
    end.

requirements(Request, #{under := Under, inner := Inner}) ->
    Under:requirements(Request, Inner).

%% The state carries the artifact, because `classify/2' is given a state and
%% never an artifact, and it is where the harness's pid has to come from.
prepare(Request, #{under := Under, inner := Inner} = A, Env) ->
    case Under:prepare(Request, Inner, Env) of
        {ok, Spec, State} -> {ok, Spec, {?MODULE, A, State}};
        {error, E, State} -> {error, E, {?MODULE, A, State}};
        Other             -> Other
    end.

classify(IR, {?MODULE, #{under := Under, harness := H}, State}) ->
    H ! {ready, self()},
    receive go -> ok end,
    Under:classify(IR, State).

decode(Result, {?MODULE, #{under := Under}, State}) ->
    Under:decode(Result, State).

cleanup({?MODULE, #{under := Under}, State}) -> Under:cleanup(State).

capabilities(#{under := Under, inner := Inner}) -> Under:capabilities(Inner).

conformance_fixtures(#{under := Under, inner := Inner}) ->
    Under:conformance_fixtures(Inner).

snapshot_capability(#{under := Under, inner := Inner}) ->
    case erlang:function_exported(Under, snapshot_capability, 1) of
        false -> unsupported;
        true  -> Under:snapshot_capability(Inner)
    end.
