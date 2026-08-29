-module(perinstr).
-export([main/1]).

%% The marginal cost of one instruction: build the same loop with K copies of a
%% snippet and with 2K, and take the difference. Everything the two runs share,
%% loop overhead included, cancels.
main(_) ->
    {ok, _} = application:ensure_all_started(wasm),
    Cases =
        [{"nop                    ", "(nop)", 1},
         {"i32.const + drop       ", "(drop (i32.const 7))", 2},
         {"local.get + drop       ", "(drop (local.get $i))", 2},
         {"local.get + local.set  ", "(local.set $t (local.get $i))", 2},
         {"i32.add                ", "(local.set $t (i32.add (local.get $t) (local.get $i)))", 4},
         {"i32.eqz + drop         ", "(drop (i32.eqz (local.get $i)))", 3},
         {"i32.ge_u + drop        ", "(drop (i32.ge_u (local.get $i) (local.get $i)))", 4},
         {"i64.add                ", "(local.set $u (i64.add (local.get $u) (i64.const 1)))", 3},
         {"f64.add                ", "(local.set $f (f64.add (local.get $f) (f64.const 1)))", 3},
         {"i32.load               ", "(local.set $t (i32.load (i32.const 0)))", 3},
         {"call (empty func)      ", "(call $empty)", 1}],
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
    {ok, I} = wasm:instantiate(M, #{}),
    N = 200000,
    R = lists:min([element(1, timer:tc(fun() -> wasm:call(I, ~"bench", [N]) end))
                   || _ <- lists:seq(1, 5)]),
    ok = wasm:destroy(I),
    R * 1000 / N.

source(Snippet, K) ->
    Body = lists:duplicate(K, [Snippet, "\n        "]),
    iolist_to_binary(
      ["(module (memory 1)\n",
       " (func $empty)\n",
       " (func (export \"bench\") (param $n i32) (result i32)\n",
       "  (local $i i32) (local $t i32) (local $u i64) (local $f f64)\n",
       "  (block $done (loop $l\n",
       "    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))\n        ",
       Body,
       "    (local.set $i (i32.add (local.get $i) (i32.const 1)))\n",
       "    (br $l)))\n",
       "  (local.get $t)))\n"]).
