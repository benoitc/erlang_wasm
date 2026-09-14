-module(js_worker).
-moduledoc """
Run a JavaScript function that arrives at request time.

The `script_v1` profile with the arguments unpacked: you hand it source and a
context, it hands you back what `main` returned.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/js"}),
{ok, W} = js_worker:start_link("test/fixtures/lang/qjs.wasm", #{root => scratch}),
{ok, #{result := #{~"answer" := 42}}} =
    js_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                  #{~"value" => 41}).
```

The tenant writes one thing:

```javascript
export function main(context) {
    return { answer: context.value + 1 };
}
```

## What it does not promise

**A runtime module resolver.** `import` resolves the absolute path the host
staged and nothing else. npm works the way it works on Workers: bundle before
submitting, and what is absent is the *resolver*, not the packages.

**Node built-ins.** None. `std` is QuickJS's own and the bootstrap uses it;
nothing re-exports `fs` or `path`.

**A network.** Denied here by choice rather than missing: an absent `net` key
is no network at all, however much the engine imports. Granting it is a
`wasi_net` rule naming addresses and ports, and note what those knobs are:
`max_sockets` caps the descriptors an instance holds **at once** and `timeout`
bounds **one blocking call**, so neither is a subrequest budget.

**Threads, `Worker`, or an event loop that outlives the call.** The profile is
a finite sequence of calls, and the deadline is wall clock.

**The WasmEdge extensions** the interim artifact carries. See
`test/fixtures/lang/QUICKJS.md` for what that build actually is.
""".

-export([start_link/2, start_link/3, stop/1, run/3, submit/3, await/3, cancel/2]).

-doc "Start a worker over a QuickJS build. `Opts` is `script_worker`'s.".
-spec start_link(file:filename_all(), map()) -> {ok, pid()} | {error, term()}.
start_link(EnginePath, Opts) ->
    script_worker:start_link(qjs_adapter, Opts#{path => EnginePath}).

-spec start_link(gen_server:server_name(), file:filename_all(), map()) ->
          {ok, pid()} | {error, term()}.
start_link(Name, EnginePath, Opts) ->
    script_worker:start_link(Name, qjs_adapter, Opts#{path => EnginePath}).

-spec stop(gen_server:server_ref()) -> ok.
stop(W) -> script_worker:stop(W).

-doc """
Run one script and wait for its answer.

**No timeout argument**, deliberately: the worker owns the deadline, and a
second timer here would only create the case where both expire together.
""".
-spec run(gen_server:server_ref(), binary(), term()) ->
          script_worker:outcome() | {error, worker_error:worker_error()}.
run(W, Source, Context) -> script_worker:run(W, request(Source, Context)).

-spec submit(gen_server:server_ref(), binary(), term()) ->
          {ok, reference()} | {error, worker_error:worker_error()}.
submit(W, Source, Context) -> script_worker:submit(W, request(Source, Context)).

-spec await(gen_server:server_ref(), reference(), timeout()) ->
          script_worker:outcome() | {error, worker_error:worker_error()}.
await(W, Ref, Timeout) -> script_worker:await(W, Ref, Timeout).

-spec cancel(gen_server:server_ref(), reference()) ->
          ok | {error, worker_error:worker_error()}.
cancel(W, Ref) -> script_worker:cancel(W, Ref).

%% The wrapper invents no deadline: the worker's `timeout' ceiling, set at
%% `start_link/2', is the only one.
request(Source, Context) -> #{source => Source, context => Context}.
