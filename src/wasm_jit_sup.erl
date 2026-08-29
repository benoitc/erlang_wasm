-module(wasm_jit_sup).
-moduledoc """
The processes that compile modules, under supervision.

Compiling runs off the calling process, so it is a process, and a process that
is not in the supervision tree is one nothing can see, bound or stop. These are
in it.

## Why the children take no arguments

A child is started empty and then *sent* the work:

```erlang
{ok, Pid} = supervisor:start_child(?MODULE, []),
Pid ! {compile, Inst, Limits, Executed}
```

Passing the instance as a start argument is the ordinary shape and it would copy
it twice, once into this supervisor and once into the child. A real instance is
35 MB, and this happens once per module. A message copies it once, straight to
the process that needs it.

## Why the children are temporary and brutally killed

`temporary`, because a compile that crashed must not be tried again by the
supervisor: whether to try again is `wasm_jit`'s decision and it makes it on the
next hot call. Restarting here would recompile with no instance to hand it to.

`brutal_kill`, because a compile takes tens of seconds and nothing waits for it.
Shutting a node down must not wait either. The slot the child reserved is
released by `wasm_code_slots`'s monitor when it dies, and the instance's own
record of having asked expires on its own, so being killed at any moment costs
nothing but the work.

## Why the bound is not a supervisor flag

An OTP supervisor has no `max_children`; that belongs to pool libraries. The
bound is a `count_children/1` check in `wasm_jit` before asking for a child, and
it is a soft one, which is all that is needed: the hard bound is the sixteen
code slots, and a compiler that cannot get one gives up at once. The check is
there to stop a seventeenth *copying an instance* to find that out.
""".
-behaviour(supervisor).

-export([start_link/0, init/1, start_compiler/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 0, period => 1},
    Child = #{id => compiler,
              start => {?MODULE, start_compiler, []},
              restart => temporary,
              shutdown => brutal_kill,
              type => worker,
              modules => [wasm_jit]},
    {ok, {Flags, [Child]}}.

-doc """
Start one compiler, which then waits to be told what to compile.

The wait has a deadline. A child whose sender died between starting it and
sending it the work would otherwise sit in the tree for the life of the node.
""".
-spec start_compiler() -> {ok, pid()}.
start_compiler() ->
    {ok, proc_lib:spawn_link(fun wasm_jit:compiler_loop/0)}.
