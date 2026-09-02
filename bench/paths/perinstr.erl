-module(perinstr).
-export([main/1]).

%% Two things have to be true of a snippet repeated K times before it measures
%% anything, and this file has now got each of them wrong once:
%%
%%   - the result must be used, or it is dead code and the SSA pass drops it;
%%   - each copy must depend on the copy before it. Forty `local.set $t' from
%%     independent expressions are thirty-nine dead stores, and one operand
%%     that does not change across iterations is hoisted out of the loop.
%%
%% So the result accumulates into the local it reads, and one operand is xored
%% with the loop counter. That is what `i32.add' has always done, which is why
%% it was the row that reported a number while `i32.shl' reported zero.
-define(VARY(Op, Operand),
        "(local.set $t (i32.add (local.get $t) (" Op
        " (i64.xor (local.get " Operand
        ") (i64.extend_i32_u (local.get $i))) (i64.const 5))))").
-define(VARYSH(Op, Operand),
        "(local.set $u (i64.add (local.get $u) (" Op
        " (i64.xor (local.get " Operand
        ") (i64.extend_i32_u (local.get $i))) (i64.const 1))))").

%% The marginal cost of one instruction: build the same loop with K copies of a
%% snippet and with 2K, and take the difference. Everything the two runs share,
%% loop overhead included, cancels.
%%
%%     erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
%%         -run perinstr main off      % the interpreter
%%     erl ... -run perinstr main on   % generated code
%%
%% The tier arm is the one that matters now. A warm QuickJS run makes *zero*
%% `wasm_exec:run/3` calls (`bench/paths/tiered.erl`), so nothing it does is
%% interpreted and only these prices explain where its time goes.
%% An optional second argument runs only the cases whose name contains it, so
%% a probe into one instruction does not pay for `memory.copy 1024B' twice.
main([Tier]) -> main([Tier, ""]);
main([Tier, Only]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Opts = case Tier of
               "off" -> #{};
               %% Whole-module and synchronous, so the loop being timed is
               %% compiled before the first measured call rather than during it.
               "on" -> #{compile => true, compile_sync => true,
                         compile_after => 1, compile_whole => true}
           end,
    put(opts, Opts),
    Cases =
        [{"nop                    ", "(nop)", 1},
         {"i32.const + drop       ", "(drop (i32.const 7))", 2},
         {"local.get + drop       ", "(drop (local.get $i))", 2},
         {"local.get + local.set  ", "(local.set $t (local.get $i))", 2},
         {"i32.add                ", "(local.set $t (i32.add (local.get $t) (local.get $i)))", 4},
         {"i32.eqz -> local        ", "(local.set $t (i32.eqz (local.get $i)))", 3},
         {"i32.eqz in br_if        ", "(if (i32.eqz (local.get $t)) (then (nop)))", 3},
         {"i32.wrap_i64            ", "(local.set $t (i32.wrap_i64 (local.get $u)))", 3},
         {"i64.extend_i32_u        ", "(local.set $u (i64.extend_i32_u (local.get $i)))", 3},
         {"i32.ge_u + drop        ", "(drop (i32.ge_u (local.get $i) (local.get $i)))", 4},
         {"i64.add                ", "(local.set $u (i64.add (local.get $u) (i64.const 1)))", 3},
         {"f64.add                ", "(local.set $f (f64.add (local.get $f) (f64.const 1)))", 3},
         {"i32.load               ", "(local.set $t (i32.load (i32.const 0)))", 3},
         {"call (empty func)      ", "(call $empty)", 1},
         %% Everything below is here because QuickJS pays for it and the
         %% original set did not cover it.
         {"i32.store              ", "(i32.store (i32.const 0) (local.get $i))", 3},
         {"i32.load8_u            ", "(local.set $t (i32.load8_u (i32.const 1)))", 3},
         {"i32.store8             ", "(i32.store8 (i32.const 1) (local.get $i))", 3},
         {"i64.load               ", "(local.set $u (i64.load (i32.const 0)))", 3},
         {"i64.store              ", "(i64.store (i32.const 0) (local.get $u))", 3},
         {"f64.load               ", "(local.set $f (f64.load (i32.const 0)))", 3},
         {"f64.store              ", "(f64.store (i32.const 0) (local.get $f))", 3},
         {"f64.convert_i32_u      ", "(local.set $f (f64.convert_i32_u (local.get $i)))", 3},
         {"i32.trunc_f64_u        ", "(local.set $t (i32.trunc_f64_u (local.get $f)))", 3},
         {"f64.mul                ", "(local.set $f (f64.mul (local.get $f) (local.get $f)))", 3},
         {"i32.mul                ", "(local.set $t (i32.mul (local.get $t) (local.get $i)))", 4},
         {"i32.div_u              ", "(local.set $t (i32.div_u (local.get $i) (i32.const 3)))", 4},
         {"i32.shl                ", "(local.set $t (i32.shl (local.get $t) (i32.const 1)))", 4},
         {"i64.shl                ", "(local.set $u (i64.shl (local.get $u) (i64.const 1)))", 4},
         {"call_indirect          ", "(call_indirect (type $void) (i32.const 0))", 2},
         {"global.get + drop      ", "(drop (global.get $g))", 2},
         {"global.set             ", "(global.set $g (local.get $i))", 2},
         {"memory.copy 8B         ", "(memory.copy (i32.const 0) (i32.const 4096) (i32.const 8))", 4},
         {"memory.copy 64B        ", "(memory.copy (i32.const 0) (i32.const 4096) (i32.const 64))", 4},
         {"memory.copy 1024B      ", "(memory.copy (i32.const 0) (i32.const 4096) (i32.const 1024))", 4},
         {"memory.fill 1024B      ", "(memory.fill (i32.const 0) (i32.const 7) (i32.const 1024))", 4},
         %% QuickJS executes 132,583,392 `block` entries a run against 2.2
         %% million `local.get`: its bytecode dispatch is a `br_table` inside a
         %% deep nest of them, and every dispatch re-enters the whole nest.
         {"block, empty           ", "(block (nop))", 1},
         {"block x8 nested        ", "(block (block (block (block (block (block (block (block (nop)))))))))", 8},
         %% What `wasm_core:uns(64, _)' costs. It is `band 16#FFFFFFFFFFFFFFFF',
         %% a literal past the 60-bit immediate range, on values already held
         %% in [-2^63, 2^63), and it is reached by `i64.shr_u' and by every
         %% unsigned 64-bit comparison. Not by `i64.div_u' or `i64.rem_u':
         %% neither has an `inline/1' clause, so both call `wasm_exec:op2/3'.
         %%
         %% Each unsigned form sits next to its signed twin, which does no
         %% masking at all, and each pair runs twice: on a value that is small
         %% and non-negative, and on one with the top bit set, because a range
         %% test would treat those two differently and a mask does not.
         %% `$h' comes from the loop bound so it cannot be folded away.
         %% `local.set' and not `drop': every one of these measured 0.00 in the
         %% `drop' form, because a computation whose result is dropped is dead
         %% and the SSA pass removes it. `$t' and `$u' are locals, and a
         %% `local.set' to a local nothing reads survives, which is why the
         %% rows above are written that way too.
         %% Read these as *pairs*: each unsigned form sits next to its signed
         %% twin, which is the same instruction without the mask, and the
         %% difference between the two is what `uns/2' costs. Neither absolute
         %% number means much, because both carry the `xor' and the extend.
         %%
         %% Those two are what make the operand vary. Written against a
         %% loop-invariant local the whole expression is hoisted out of the
         %% loop and every row reads 0.00, which is how the first version of
         %% these rows reported that unsigned comparison is free.
         {"i64.lt_s, small       ", ?VARY("i64.lt_s", "$sm"), 9},
         {"i64.lt_u, small       ", ?VARY("i64.lt_u", "$sm"), 9},
         {"i64.lt_s, high bit    ", ?VARY("i64.lt_s", "$h"), 9},
         {"i64.lt_u, high bit    ", ?VARY("i64.lt_u", "$h"), 9},
         {"i64.ge_s, high bit    ", ?VARY("i64.ge_s", "$h"), 9},
         {"i64.ge_u, high bit    ", ?VARY("i64.ge_u", "$h"), 9},
         {"i64.shr_s, small      ", ?VARYSH("i64.shr_s", "$sm"), 9},
         {"i64.shr_u, small      ", ?VARYSH("i64.shr_u", "$sm"), 9},
         {"i64.shr_s, high bit   ", ?VARYSH("i64.shr_s", "$h"), 9},
         {"i64.shr_u, high bit   ", ?VARYSH("i64.shr_u", "$h"), 9},
         {"br_table 4 of 8 nested ",
          "(block $a (block $b (block $c (block $d (block $e (block $f (block $g (block $h (br_table $a $b $c $d $e $f $g $h (local.get $i))))))))))",
          9}],
    io:format("~-24s ~10s ~10s~n", ["snippet", "ns/snip", "ns/instr"]),
    [run_case(Name, Snip, Instrs) || {Name, Snip, Instrs} <- Cases,
                                     string:find(Name, Only) =/= nomatch],
    init:stop().

run_case(Name, Snippet, Instrs) ->
    K = 20,
    T1 = time_for(Snippet, K),
    T2 = time_for(Snippet, 2 * K),
    Per = (T2 - T1) / K,
    io:format("~-24s ~10.2f ~10.2f~s~n", [Name, Per, Per / Instrs, note(Per)]).

%% A snippet that costs nothing usually was not run. Ten of them were added to
%% this file in the `(drop ...)' form, which is dead code the SSA pass removes,
%% and every one reported 0.00 as though the instruction were free. Say so in
%% the row rather than leaving a reader to notice the zero.
note(Per) when Per < 0.05 -> "   <- eliminated, or below the noise floor";
note(_Per) -> "".

%% ns per iteration for a loop whose body holds `K' copies of the snippet
time_for(Snippet, K) ->
    Src = source(Snippet, K),
    {ok, P} = wasm_wat:module(Src),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}, get(opts)),
    N = 200000,
    %% One call to trigger and finish the compile, so the timed ones are
    %% measuring generated code and not the compiler.
    _ = wasm:call(I, ~"bench", [1]),
    R = lists:min([element(1, timer:tc(fun() -> wasm:call(I, ~"bench", [N]) end))
                   || _ <- lists:seq(1, 5)]),
    ok = wasm:destroy(I),
    R * 1000 / N.

source(Snippet, K) ->
    Body = lists:duplicate(K, [Snippet, "\n        "]),
    iolist_to_binary(
      ["(module (memory 1)\n",
       " (func $empty)\n",
       " (type $void (func))\n",
       " (table 1 1 funcref)\n",
       " (elem (i32.const 0) $empty)\n",
       " (global $g (mut i32) (i32.const 0))\n",
       " (func (export \"bench\") (param $n i32) (result i32)\n",
       "  (local $i i32) (local $t i32) (local $u i64) (local $f f64)\n",
       "  (local $h i64) (local $sm i64)\n",
       %% Every bit set above the loop bound, so `$h' is high-bit unsigned and
       %% comes from a parameter: a constant would be propagated into the loop
       %% and the masks folded away with it.
       "  (local.set $h (i64.sub (i64.const 0) (i64.extend_i32_u (local.get $n))))\n",
       "  (local.set $sm (i64.extend_i32_u (local.get $n)))\n",
       "  (block $done (loop $l\n",
       "    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))\n        ",
       Body,
       "    (local.set $i (i32.add (local.get $i) (i32.const 1)))\n",
       "    (br $l)))\n",
       "  (local.get $t)))\n"]).
