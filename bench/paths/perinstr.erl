-module(perinstr).
-export([main/1]).

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
main([Tier]) ->
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
         {"memory.copy 64B        ", "(memory.copy (i32.const 0) (i32.const 4096) (i32.const 64))", 4}],
    io:format("~-24s ~10s ~10s~n", ["snippet", "ns/snip", "ns/instr"]),
    [run_case(Name, Snip, Instrs) || {Name, Snip, Instrs} <- Cases],
    init:stop().

run_case(Name, Snippet, Instrs) ->
    K = 20,
    T1 = time_for(Snippet, K),
    T2 = time_for(Snippet, 2 * K),
    Per = (T2 - T1) / K,
    io:format("~-24s ~10.2f ~10.2f~n", [Name, Per, Per / Instrs]).

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
       "  (block $done (loop $l\n",
       "    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))\n        ",
       Body,
       "    (local.set $i (i32.add (local.get $i) (i32.const 1)))\n",
       "    (br $l)))\n",
       "  (local.get $t)))\n"]).
