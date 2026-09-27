-module(storebench).
-moduledoc """
What a store costs in generated code, and what tracking which chunks it wrote
adds to it.

Use it before changing the inlined store in `wasm_core`, or anything a store
reads from the memory handle. A loop of `i32.store` and `i64.store` over 64 KiB
runs with the tier forced on; the arm says whether the memory tracks its
writes the way a recycling restore's does.

    erlc -o bench/paths -I include -pa _build/default/lib/wasm/ebin \\
        bench/paths/storebench.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run storebench main plain
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run storebench main tracked

Interleave the arms, and against another build, and take minimums: the
difference being measured is a few nanoseconds.
""".
-export([main/1]).

-include("wasm_exec.hrl").

-define(WAT, ~"(module (memory (export \"m\") 16)
  (func (export \"run\") (param $n i32) (local $i i32)
    (loop $l
      (i32.store (i32.and (i32.shl (local.get $i) (i32.const 2)) (i32.const 65532))
                 (local.get $i))
      (i64.store offset=65536
                 (i32.and (i32.shl (local.get $i) (i32.const 3)) (i32.const 65528))
                 (i64.extend_i32_u (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))))").

main([Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, M} = wasm:compile({wat, ?WAT}),
    Opts = #{compile => true, compile_after => 1, compile_force => true,
             fuel => infinity},
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    ok = warm(I, Opts, 200),
    ok = arm(Arm, I),
    N = 2_000_000,
    Ts = [element(1, timer:tc(fun() -> {ok, []} = wasm:call(I, ~"run", [N], Opts) end))
          || _ <- lists:seq(1, 9)],
    io:format("~s: ~.2f ns per store (minimum of 9 runs of ~p stores), entered ~p~n",
              [Arm, lists:min(Ts) * 1000 / (2 * N), 2 * N,
               maps:get(entered, wasm_jit:counts())]),
    halt().

%% A tracking memory, as `wasm_snapshot' makes one after laying an image.
arm("tracked", I) ->
    Mut = wasm_instance:mut(I),
    {Mem} = Mut#mut.mems,
    wasm_instance:set_mut(I, Mut#mut{mems = {wasm_memory:track(Mem, 16)}});
arm(_Plain, _I) ->
    ok.

%% Until generated code is being entered, so the timed runs are compiled.
warm(_I, _Opts, 0) -> ok;
warm(I, Opts, K) ->
    {ok, []} = wasm:call(I, ~"run", [1000], Opts),
    case maps:get(entered, wasm_jit:counts()) of
        E when E > 3 -> ok;
        _ -> timer:sleep(20), warm(I, Opts, K - 1)
    end.
