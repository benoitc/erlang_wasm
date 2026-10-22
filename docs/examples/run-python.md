# Run Python

This example runs Python source text, through the worker kernel and the
CPython adapter. The script defines `main`. The worker calls it with a
context, and returns its result.

**You need:** the CPython build, downloaded by
`scripts/fetch-python-fixture.sh` into `test/fixtures/lang/python.wasm`. You
also need patience: this build starts CPython for every request, which takes
a minute or more.

CPython needs more than the untrusted defaults allow, so the limits below are
raised on purpose:

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

**What happened.** The same kernel as in [Run JavaScript](run-javascript.md)
ran the script, with the CPython adapter. Each limit above was measured;
[Python](../python.md) explains each value.

The reactor build, `wasm_python`, starts CPython once and restores a snapshot
for each request. A request then takes about a third of a second instead of a
minute or more. It takes under 100 ms once you add the heap floors (minimum
process heap sizes) that [Python](../python.md) describes.

**Clean up:**

<!-- check: needs python -->
```erlang
ok = wasm_script_worker:stop(W).
```

**Next:** [Put it in an OTP application](../otp.md).

## Read this next

The guide behind this example: [Python](../python.md).
