# Run JavaScript

This example runs JavaScript that arrives as text, through the worker kernel
and the QuickJS adapter. The script exports `main`; the worker gives it a
context and returns what it returns.

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
request its own processes and a deadline, five seconds unless you set
`timeout`. The **adapter**, `wasm_javascript_command`, knows how to start
QuickJS, hand it the script and the context as JSON, and read the result
back. The script got one read-only directory holding its own source, and
nothing else: no network, no other files.

This build starts QuickJS for every request. `wasm_javascript` with the
reactor build starts it once and restores a snapshot per request instead; see
[JavaScript](../javascript.md).

**Clean up:**

<!-- check: needs qjs -->
```erlang
ok = wasm_script_worker:stop(W).
```

**Next:** [Run Python](run-python.md).
