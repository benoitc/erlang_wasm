# Stop a runaway

This example runs a guest that never returns, twice: once limited by a work
budget, and once by a deadline. A call made directly runs in your process,
and nothing can interrupt it. So a deadline needs the instance in a process
of its own: a **worker**.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, Spin} = wasm:compile({wat, ~"(module (func (export \"spin\") (loop $l (br $l))))"}).
```

**Limited by fuel.** **Fuel** is a work budget: the guest stops after it has
done that much work, and the worker keeps running.

```erlang
{ok, W} = wasm_instance_worker:start_link(Spin, #{limits => wasm_limits:untrusted()}),
wasm_instance_worker:call(W, ~"spin", [], 5000).
%% => {error, #{class := exhaustion, kind := out_of_fuel}}
```

**Limited by time.** With no fuel limit, only the deadline can stop the
guest. When the deadline passes, the worker is killed. So the work really
stops, and does not keep running with nobody waiting for it:

<!-- check: expect-exit killed -->
```erlang
{ok, W2} = wasm_instance_worker:start_link(Spin, #{limits => #{fuel => infinity}}),
wasm_instance_worker:call(W2, ~"spin", [], 200).
%% => {error, #{class := exhaustion, kind := timeout}}
```

**What happened.** Fuel counts work, not time: a guest that waits in a host
function uses none. A deadline counts time, and needs a separate process. For
untrusted code, use both. The killed worker was linked to your shell process,
so the shell shows it exiting. Put workers under a supervisor, as
[Put it in an OTP application](../otp.md) shows.

**Clean up:**

```erlang
ok = wasm_instance_worker:stop(W).
```

**Next:** [A plugin per request](plugin-per-request.md).

## Read this next

The guide behind this example: [Using workers](../worker.md).
