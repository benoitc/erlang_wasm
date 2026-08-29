-module(callcost).
-moduledoc """
What a call costs the interpreter, and what it would cost a compiled function.

Use this before building a Core Erlang back end. `subset` showed that a
compiler which cannot call is worth nothing on real code: without calls it
covers 3.2% of QuickJS by instruction, with them 73.8%. So the boundary is the
first thing the back end needs, and its cost decides the project. A compiled
body that runs 20x faster loses anyway if every call out of it costs more than
the body saved.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/callcost.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths -pa bench/cross \\
        -run callcost main

## The two shapes, and why they are not the same

Inside the interpreter a call is a *trampoline*: `enter/5` stashes the caller's
continuation in `#st.frames` and tail-calls `run/3` with the callee's body, and
`leave/2` later resumes the continuation. No Erlang stack frame is used and no
state is rebuilt.

A compiled function cannot do that. Its continuation is a Core Erlang frame,
not an instruction list, so it has to make a *nested* invocation: build a
state, run the callee to completion, take the results back. That is exactly
what `wasm_exec:call/5` does, and it is what `foreign_call` already uses for a
call into another instance. Timing it from Erlang measures the floor for a
compiled caller with no compiler written.

The floor is a floor in both directions: it omits the state a compiled caller
would also have to thread, and it omits the interpreted body the compiled
callee would not run.
""".
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

-define(ROUNDS, 7).

main(_) ->
    {ok, _} = application:ensure_all_started(wasm),
    jit = erlang:system_info(emu_flavor),
    {ok, P} = wasm_wat:module(source()),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}, #{}),

    %% `inner' is the first function declared, and this is what says so. A
    %% wrong index would otherwise time a different function silently.
    Mut = wasm_instance:mut(I),
    Limits = I#inst.limits,
    {ok, [42], _} = wasm_exec:call(I, Mut, 0, [41], Limits),

    Sizes = loop_erl:sizes(200000),
    Arms = [{"loop, no call", fun(N) -> guest(I, ~"empty", N) end},
            {"loop, calling", fun(N) -> guest(I, ~"outer", N) end},
            {"nested invocation", fun(N) -> nested(I, Mut, Limits, N) end}],

    Slopes =
        [begin
             [_ = F(1000) || _ <- lists:seq(1, 3)],      % warmup, in this process
             Points = [{N, best(F, N)} || N <- Sizes],
             {S, _, R2} = loop_erl:fit(Points),
             io:format("~-20s ~8.1f ns/iter  r2=~.5f~n", [Name, S * 1000, R2]),
             {Name, S * 1000}
         end || {Name, F} <- Arms],

    [{_, Empty}, {_, Outer}, {_, Nested}] = Slopes,
    io:format("~ninterpreted call, trampolined ~8.1f ns~n", [Outer - Empty]),
    io:format("nested invocation, the floor  ~8.1f ns~n", [Nested]),
    io:format("ratio                         ~8.1f x~n", [Nested / (Outer - Empty)]),
    init:stop().

best(F, N) ->
    float(lists:min([element(1, timer:tc(fun() -> F(N) end))
                     || _ <- lists:seq(1, ?ROUNDS)])).

guest(I, Name, N) ->
    {ok, [_]} = wasm:call(I, Name, [N]),
    ok.

%% One nested invocation per iteration, with the mutable state threaded exactly
%% as a caller has to thread it.
nested(I, Mut, Limits, N) -> nested(I, Mut, Limits, N, 0).

nested(_I, _Mut, _Limits, 0, A) -> A;
nested(I, Mut, Limits, N, A) ->
    {ok, [A1], Mut1} = wasm_exec:call(I, Mut, 0, [A], Limits),
    nested(I, Mut1, Limits, N - 1, A1).

%% `outer' and `empty' differ in exactly one thing: whether the accumulator is
%% incremented by a call or in line. Their difference is one call and nothing
%% else.
source() -> ~"""
(module
  (func $inner (export "inner") (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.add)
  (func (export "outer") (param i32) (result i32)
    (local $i i32) (local $a i32)
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get 0)))
        (local.set $a (call $inner (local.get $a)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    local.get $a)
  (func (export "empty") (param i32) (result i32)
    (local $i i32) (local $a i32)
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get 0)))
        (local.set $a (i32.add (local.get $a) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    local.get $a))
"""
.
