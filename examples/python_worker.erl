-module(python_worker).
-moduledoc """
Run a Python function that arrives at request time.

The `script_v1` profile with the arguments unpacked: you hand it source and a
context, it hands you back what `main` returned.

```erlang
{ok, _} = wasm_worker_reaper:start_link(#{scratch => "/var/tmp/py"}),
{ok, W} = python_worker:start_link("test/fixtures/lang/python.wasm",
                                   #{root => scratch, limits => Limits}),
{ok, #{result := #{~"answer" := 42}}} =
    python_worker:run(W, ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
                      #{~"value" => 41}).
```

The tenant writes one thing:

```python
def main(context):
    return {"answer": context["value"] + 1}
```

## Raise the ceilings knowingly

`wasm_limits:untrusted/0` is built for something much smaller than an
interpreter, and an adapter never raises a ceiling behind your back. CPython
needs `timeout`, `max_memory_pages` and `max_heap_words` raised, and
`test/fixtures/lang/PYTHON.md` records what each was measured at. A larger
`max_heap_words` is not better: 16M words ran a request in 48 s here and 64M
took 85 s, because a bigger bound lets the heap grow and the collections cost
more.

## What it does not promise

**Arbitrary PyPI wheels or native extension modules.** Anything with C in it
has to be built for `wasm32-wasip1` and linked into the interpreter.

**`subprocess`, threading or ordinary sockets.** Not this runtime's doing:
**CPython itself disables them on WASI**, so the absence is upstream rather
than something taken away here.

**Pyodide compatibility.** Different target, different glue, different package
loader. Nothing here should imply a Pyodide package runs unchanged.

**A network.** Denied by choice rather than missing, the same as everywhere
else: granting it is a `wasi_net` rule, and `max_sockets` caps concurrent
descriptors while `timeout` bounds one blocking call, so neither is a
subrequest budget.
""".

-export([start_link/2, start_link/3, stop/1, run/3, submit/3, await/3, cancel/2]).

-doc "Start a worker over a CPython build. `Opts` is `wasm_script_worker`'s.".
-spec start_link(file:filename_all(), map()) -> {ok, pid()} | {error, term()}.
start_link(EnginePath, Opts) ->
    wasm_script_worker:start_link(wasm_python_command, Opts#{path => EnginePath}).

-spec start_link(gen_server:server_name(), file:filename_all(), map()) ->
          {ok, pid()} | {error, term()}.
start_link(Name, EnginePath, Opts) ->
    wasm_script_worker:start_link(Name, wasm_python_command, Opts#{path => EnginePath}).

-spec stop(gen_server:server_ref()) -> ok.
stop(W) -> wasm_script_worker:stop(W).

-doc """
Run one script and wait for its answer.

**No timeout argument**, deliberately: the worker owns the deadline, and a
second timer here would only create the case where both expire together.
""".
-spec run(gen_server:server_ref(), binary(), term()) ->
          wasm_script_worker:outcome() | {error, wasm_worker_error:worker_error()}.
run(W, Source, Context) -> wasm_script_worker:run(W, request(Source, Context)).

-spec submit(gen_server:server_ref(), binary(), term()) ->
          {ok, reference()} | {error, wasm_worker_error:worker_error()}.
submit(W, Source, Context) -> wasm_script_worker:submit(W, request(Source, Context)).

-spec await(gen_server:server_ref(), reference(), timeout()) ->
          wasm_script_worker:outcome() | {error, wasm_worker_error:worker_error()}.
await(W, Ref, Timeout) -> wasm_script_worker:await(W, Ref, Timeout).

-spec cancel(gen_server:server_ref(), reference()) ->
          ok | {error, wasm_worker_error:worker_error()}.
cancel(W, Ref) -> wasm_script_worker:cancel(W, Ref).

%% The wrapper invents no deadline: the worker's `timeout' ceiling, set at
%% `start_link/2', is the only one.
request(Source, Context) -> #{source => Source, context => Context}.
