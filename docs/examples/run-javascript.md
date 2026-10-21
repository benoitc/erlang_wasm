# Run JavaScript

This example runs JavaScript source text, through the worker kernel and the
QuickJS adapter. The script exports `main`. The worker calls it with a
context, and returns its result.

**You need:** the QuickJS build, fetched by `scripts/fetch-qjs-fixture.sh`
into `test/fixtures/lang/qjs.wasm`.

<!-- check: needs qjs -->
```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}).
```

Run a script:

<!-- check: needs qjs -->
```erlang
Script = ~"export function main(c) { return {answer: c.value + 1}; }",
{ok, #{result := Result}} = wasm_script_worker:run(W, Script, #{~"value" => 41}),
Result.
%% => #{~"answer" := 42}
```

**What happened.** The **worker kernel**, `wasm_script_worker`, gave the
request its own processes and a deadline: five seconds, unless you set
`timeout`. The **adapter**, `wasm_javascript_command`, knows how to start
QuickJS, give it the script and the context as JSON, and read the result.
The script got one read-only directory that holds its own source, and
nothing else: no network, no other files.

This build starts QuickJS for every request. `wasm_javascript`, with the
reactor build, starts it once and restores a snapshot for each request
instead; see [JavaScript](../javascript.md).

**Clean up:**

<!-- check: needs qjs -->
```erlang
ok = wasm_script_worker:stop(W).
```

**Next:** [Run Python](run-python.md).

## Read this next

The guide behind this example: [JavaScript](../javascript.md).
