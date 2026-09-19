# Stop a runaway

This example runs a guest that never returns, twice: once bounded by a work
budget, once by a deadline. A call made directly runs in your process and
cannot be interrupted, so a deadline needs the instance in a process of its
own, a **worker**.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, Spin} = wasm:compile({wat, ~"(module (func (export \"spin\") (loop $l (br $l))))"}).
```

**Bounded by fuel.** **Fuel** is a work budget: the guest stops when it has
done that much work, and the worker carries on.

```erlang
{ok, W} = wasm_instance_worker:start_link(Spin, #{limits => wasm_limits:untrusted()}),
wasm_instance_worker:call(W, ~"spin", [], 5000).
%% => {error, #{class := exhaustion, kind := out_of_fuel}}
```

**Bounded by time.** With no fuel ceiling, only the deadline can stop it. When
it passes, the worker is killed, so the work really stops rather than running
on with nobody waiting:

<!-- check: expect-exit killed -->
```erlang
{ok, W2} = wasm_instance_worker:start_link(Spin, #{limits => #{fuel => infinity}}),
wasm_instance_worker:call(W2, ~"spin", [], 200).
%% => {error, #{class := exhaustion, kind := timeout}}
```

**What happened.** Fuel counts work, not time: a guest blocked in a host
function burns none. A deadline counts time, and costs a process. Untrusted
code wants both. The killed worker was linked to you, which is why a shell
shows it exiting; put workers under a supervisor, as
[Put it in an OTP application](../otp.md) shows.

**Clean up:**

```erlang
ok = wasm_instance_worker:stop(W).
```

**Next:** [A plugin per request](plugin-per-request.md).
