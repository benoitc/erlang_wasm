-module(wasm_lifetime).
-moduledoc """
Make a spawned process die with the process responsible for it.

Use it when a process starts a child that does real work (a compiler, a
producer, a callback, a guest's `init()`) and enforces a limit on it, such as
a deadline, from its own process. If that owner is killed, the limit goes
with it, and an unlinked child keeps running with nothing able to see it.
`bind/1` closes that gap without a link and without `trap_exit`.

```erlang
Owner = self(),
spawn(fun() ->
          ok = wasm_lifetime:bind(Owner),
          work()
      end).
```

`bind/1` must be the child's first action. It starts a watcher that monitors
both processes: if the owner dies first, the watcher kills the child; if the
child finishes first, the watcher exits quietly. Monitoring an owner that is
already dead answers at once, so there is no window in which the child runs
unwatched.

Not a link, on purpose: a child killed by its `max_heap_size` exits with
`killed`, and an untrapping owner linked to it would die with `killed` too,
before it could record the outcome. The owner is often the embedder's own
process, which is not ours to kill or to set flags on.
""".

-export([bind/1]).

-doc """
Kill the calling process if `Owner` dies before it does.

Call it first thing in the child.
""".
-spec bind(pid()) -> ok.
bind(Owner) ->
    %% Bound out here. Inside the fun, `self()` would be the watcher's own
    %% pid, so it would watch itself and leave the child it exists to stop
    %% running.
    Child = self(),
    _ = spawn(fun() -> watch(Owner, Child) end),
    ok.

watch(Owner, Child) ->
    OwnerRef = monitor(process, Owner),
    ChildRef = monitor(process, Child),
    receive
        {'DOWN', ChildRef, process, Child, _} -> ok;
        %% `exit/2' on a pid that has already gone is `true', so losing this
        %% race costs nothing.
        {'DOWN', OwnerRef, process, Owner, _} -> exit(Child, kill)
    end.
