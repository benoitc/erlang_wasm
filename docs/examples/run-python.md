# Run Python

This example runs Python that arrives as text, through the worker kernel and
the CPython adapter. The script defines `main`; the worker gives it a context
and returns what it returns.

**You need:** the CPython build, fetched by `scripts/fetch-python-fixture.sh`
into `test/fixtures/lang/python.wasm`, and patience: this build starts CPython
for every request, which takes most of a minute.

CPython needs more than the untrusted defaults allow, so the limits are raised
knowingly:

<!-- check: needs python -->
```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, W} = wasm_script_worker:start_link(
            wasm_python_command,
            #{path => "test/fixtures/lang/python.wasm",
              limits => #{timeout => 300_000,
                          max_memory_pages => 4096,
                          max_host_calls => 1_000_000,
                          max_heap_words => 16 * 1024 * 1024,
                          fuel => 4_000_000_000}}).
```

Run a script:

<!-- check: needs python -->
```erlang
Script = ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
{ok, #{result := Result}} = wasm_script_worker:run(W, Script, #{~"value" => 41}),
Result.
%% => #{~"answer" := 42}
```

**What happened.** The same kernel as [Run JavaScript](run-javascript.md), with
the CPython adapter. Each limit above was measured; [Python](../python.md)
says why each is what it is.

The reactor build, `wasm_python`, starts CPython once and restores a snapshot
per request, which brings a request from most of a minute to about a tenth of
a second.

**Clean up:**

<!-- check: needs python -->
```erlang
ok = wasm_script_worker:stop(W).
```

**Next:** [Put it in an OTP application](../otp.md).
