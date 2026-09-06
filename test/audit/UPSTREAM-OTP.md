# A report for erlang/otp, not yet filed

Ready to post to `erlang/otp` as an issue. Both findings were verified against
the installed OTP 29 (`compiler-10.0.2`) and against `compile.erl` on master,
where `do_compile/2` is unchanged. Neither is reported upstream: the only
related issue is #1972, the 2018 PR that introduced
`no_spawn_compiler_process`.

The numbers come from `PERF.md`, "Owning the compiler worker", and the
reproduction in finding 2 is the probe that led to `wasm_core:reap/2`.

---

**Title:** compile:forms/2's worker cannot be bounded and outlives a killed caller

---

`compile:forms/2` runs its passes in a process it spawns itself
(`compile.erl`, `do_compile/2`, unchanged on master):

```erlang
do_compile(Input, Opts0) ->
    Opts = expand_opts(Opts0),
    IntFun = internal_fun(Input, Opts),
    case lists:member(no_spawn_compiler_process, Opts) of
        true  -> IntFun();
        false ->
            {Pid,Ref} = spawn_monitor(fun() -> exit(IntFun()) end),
            receive {'DOWN',Ref,process,Pid,Rep} -> Rep end
    end.
```

Two consequences bite anyone compiling generated code at runtime. I hit both
building a WebAssembly-to-BEAM tier, where guest modules are compiled on a live
node while it serves traffic.

## 1. The worker cannot be given spawn options, so its memory cannot be bounded

`spawn_monitor/1` takes no options, and `max_heap_size` is not inherited, so the
worker always runs at the system default (`+hmax`). A `max_heap_size` set on the
calling process therefore bounds a process that only waits in `receive`.

Measured on OTP 29 compiling one unit of generated Core, sampling
`total_heap_size` at 50 ms:

| process | peak |
| --- | ---: |
| the caller, blocked in `do_compile/2` | 141 MB |
| the worker it is waiting on | **2,055 MB** |

So the only quantity a caller can bind is 7% of the one that matters. The
existing escape, `no_spawn_compiler_process`, moves the work onto the caller
where its ceiling applies, but that changes the topology rather than
configuring it.

**Suggested fix**, which preserves the current topology exactly:

```erlang
{compiler_spawn_options, [spawn_option()]}
```

stripped from `Opts` before the passes run, with `spawn_monitor/1` becoming
`spawn_opt/2`. `max_heap_size` is the option I need; `priority`,
`fullsweep_after` and `min_heap_size` are all plausible for other callers.
Dialyzer already reaches for `no_spawn_compiler_process`
(`dialyzer_utils.erl`), so the "I manage my own workers" case is established.

## 2. The worker is not linked, so it outlives a killed caller

`spawn_monitor/1` monitors and does not link. If the caller is killed, the
worker keeps compiling to completion, holding its own copy of the forms (the fun
closes over `Input`, so the term is copied in at spawn), with nothing able to
observe or stop it.

```erlang
1> P = spawn(fun() -> compile:forms(BigForms, [binary,return_errors]) end).
2> timer:sleep(400), exit(P, kill).
%% the worker is still alive, and still alive seconds later
```

That is a leak of a core and of however much the forms weigh, per killed
caller. It matters most for exactly the callers who need it least to matter:
supervised compilers that are shut down with `brutal_kill`, and anything torn
down by `application:stop/1`.

A link would fix it, at the cost of propagating a compiler crash to the caller,
which I assume is why it is a monitor. If the current lifetime is deliberate it
would be worth a sentence in the documentation, since "terminated at the end of
compilation" reads as a promise that it is not.

I am happy to prepare a PR for either or both if the direction is agreeable.
