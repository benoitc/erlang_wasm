-module(pathbench).
-export([main/1]).

main([Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    run(list_to_atom(Arm)),
    init:stop().

%% min of R rounds of N iterations, reported as ns per iteration
bench(Name, N, F) -> bench(Name, N, F, 5).
bench(Name, N, F, R) ->
    Ts = [begin {T, _} = timer:tc(fun() -> loop(N, F) end), T * 1000 / N end
          || _ <- lists:seq(1, R)],
    io:format("~s\t~.1f\n", [Name, lists:min(Ts)]).

loop(0, _F) -> ok;
loop(N, F) -> _ = F(), loop(N - 1, F).

fac() -> {ok, B} = file:read_file("test/fixtures/seeds/fac.wasm"), B.
plugin() -> {ok, B} = file:read_file("test/fixtures/plugin/plugin.wasm"), B.
qjs() -> {ok, B} = file:read_file("test/fixtures/lang/qjs.wasm"), B.

%%% ----------------------------------------------------------- null ---
run(null) ->
    F = fun() -> ok end,
    bench("null-a", 1000000, F),
    bench("null-b", 1000000, F);

%%% ------------------------------------------------------ front end ---
run(decode) -> B = fac(), bench("decode-fac", 2000, fun() -> wasm_decode:module(B) end);
run(validate) ->
    B = fac(), {ok, M} = wasm_decode:module(B),
    bench("validate-fac", 2000, fun() -> wasm_validate:module(M) end);
run(compile_small) -> B = plugin(), bench("compile-plugin-46k", 20, fun() -> wasm:compile(B) end, 3);
run(compile_big) -> B = qjs(), bench("compile-qjs-1.8m", 3, fun() -> wasm:compile(B) end, 3);
run(load_hit) ->
    B = plugin(), {ok, _} = wasm:load(B),
    bench("load-cache-hit", 20000, fun() -> wasm:load(B) end);

%%% ---------------------------------------------------- instantiate ---
run(inst_small) ->
    {ok, M} = wasm:compile(fac()),
    bench("instantiate-fac", 20000, fun() -> {ok, I} = wasm:instantiate(M, #{}), wasm:destroy(I) end);
run(inst_plugin) ->
    {ok, M} = wasm:compile(plugin()), Im = wasi_preview1:imports(#{}),
    bench("instantiate-plugin", 5000, fun() -> {ok, I} = wasm:instantiate(M, Im), wasm:destroy(I) end);
run(inst_big) ->
    {ok, M} = wasm:compile(qjs()), Im = wasi_preview1:imports(#{}),
    bench("instantiate-qjs-lazy", 200, fun() -> {ok, I} = wasm:instantiate(M, Im), wasm:destroy(I) end, 3);

%%% ----------------------------------------------------------- call ---
run(call) ->
    {ok, M} = wasm:compile(fac()), {ok, I} = wasm:instantiate(M, #{}),
    bench("call-fac-10", 100000, fun() -> wasm:call(I, ~"fac-rec", [10]) end);
run(call_host) ->
    Wat = ~"(module (import \"e\" \"h\" (func $h (param i32) (result i32)))
              (func (export \"f\") (param i32) (result i32) (local.get 0) (call $h)))",
    {ok, P} = wasm_wat:module(Wat), {ok, M} = wasm_validate:module(P),
    Im = #{{~"e", ~"h"} => fun(_C, [X]) -> {ok, [X + 1]} end},
    {ok, I} = wasm:instantiate(M, Im),
    bench("call-through-host-import", 200000, fun() -> wasm:call(I, ~"f", [1]) end);
run(call_indirect) ->
    Wat = ~"(module (table 4 funcref) (elem (i32.const 0) $a $b)
              (func $a (result i32) (i32.const 1)) (func $b (result i32) (i32.const 2))
              (type $t (func (result i32)))
              (func (export \"f\") (param i32) (result i32) (local.get 0) (call_indirect (type $t))))",
    {ok, P} = wasm_wat:module(Wat), {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    bench("call_indirect", 200000, fun() -> wasm:call(I, ~"f", [1]) end);

%% A long jump table, every label targeting the same block, so the arm prices
%% *selecting* a label and nothing else. The interpreter used to walk the list
%% twice per dispatch, once to count and once to index, which a 32-entry table
%% makes visible and a two-entry one does not.
run(br_table) ->
    Labels = lists:join(" ", ["$k" || _ <- lists:seq(1, 32)]),
    Wat = iolist_to_binary(
            ["(module (func (export \"sw\") (param i32) (result i32)",
             " (local $i i32) (local $a i32)",
             " (block $done (loop $lp",
             "  (br_if $done (i32.ge_s (local.get $i) (local.get 0)))",
             "  (local.set $i (i32.add (local.get $i) (i32.const 1)))",
             "  (block $k (br_table ", Labels,
             "   (i32.and (local.get $i) (i32.const 31))))",
             "  (local.set $a (i32.add (local.get $a) (i32.const 1)))",
             "  (br $lp)))",
             " (local.get $a)))"]),
    {ok, P} = wasm_wat:module(Wat), {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    bench("br_table-32-labels-x10000", 300, fun() -> wasm:call(I, ~"sw", [10000]) end);

%%% --------------------------------------------------------- memory ---
run(memory) ->
    Wat = ~"(module (memory (export \"m\") 16))",
    {ok, P} = wasm_wat:module(Wat), {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    Data = binary:copy(<<0>>, 65536),
    bench("write_memory-64k", 2000, fun() -> wasm:write_memory(I, 0, Data) end),
    bench("read_memory-64k", 2000, fun() -> wasm:read_memory(I, 0, 65536) end),
    bench("write_memory-8b", 200000, fun() -> wasm:write_memory(I, 0, <<0:64>>) end);

%%% ------------------------------------------------ store mutation ---
%%
%% A trap has to leave behind everything the computation did to the store, so
%% every mutation is checkpointed. `global.set` is the one that matters: real
%% compiler output moves a shadow stack pointer through a mutable global on
%% nearly every function entry and exit.
run(global_set) ->
    Wat = ~"(module (global $g (mut i32) (i32.const 0))
              (func (export \"f\") (param i32) (result i32)
                (local $i i32)
                (block $done (loop $l
                  (br_if $done (i32.ge_u (local.get $i) (local.get 0)))
                  (global.set $g (local.get $i))
                  (local.set $i (i32.add (local.get $i) (i32.const 1)))
                  (br $l)))
                (global.get $g)))",
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    bench("global.set-x1000", 2000, fun() -> wasm:call(I, ~"f", [1000]) end);

%%% ---------------------------------------------------- object store ---
%%
%% A module with a struct or array type gets an object store, and a store two
%% instances share is the one an execution lease has to guard. `pure` isolates
%% what a lease costs from what collecting costs: it allocates nothing, so the
%% only thing on the path is the lease itself.
run(gc_call_pure) ->
    {ok, I} = gc_instance(),
    bench("gc-call-pure-unlinked", 200000, fun() -> wasm:call(I, ~"add", [1]) end);
run(gc_call_pure_linked) ->
    {ok, A} = gc_instance(),
    {ok, B} = gc_instance(A),
    bench("gc-call-pure-linked", 200000, fun() -> wasm:call(B, ~"add", [1]) end);
run(gc_call) ->
    {ok, I} = gc_instance(),
    bench("gc-call-alloc-unlinked", 100000, fun() -> wasm:call(I, ~"alloc", [1]) end);
run(gc_call_linked) ->
    {ok, A} = gc_instance(),
    {ok, B} = gc_instance(A),
    bench("gc-call-alloc-linked", 100000, fun() -> wasm:call(B, ~"alloc", [1]) end);

%%% ------------------------------------------------- resource model ---
%%
%% Creating, growing and releasing a memory are `wasm_keeper' transactions: a
%% synchronous round trip that a lock-free counter bump did not cost. These are
%% the arms that say what that bought and what it cost.
run(mem_create) ->
    bench("memory-new+free-1page", 20000,
          fun() -> {ok, M} = wasm_memory:new(1, 1), ok = wasm_memory:free(M) end);
run(grow) ->
    Old = wasm_engine:page_limit(),
    wasm_engine:set_page_limit(1 bsl 20),
    grow_arm("memory.grow-standalone", ~"(module (memory 1 4096))", standalone),
    grow_arm("memory.grow-exported",
             ~"(module (memory (export \"m\") 1 4096))", exported),
    wasm_engine:set_page_limit(Old);

%%% ----------------------------------------------------------- wasi ---
run(wasi_write) ->
    {ok, M} = wasm:compile(plugin()),
    Im = wasi_preview1:imports(#{stdout => fun(_) -> ok end}),
    bench("instantiate+destroy plugin (wasi imports)", 5000,
          fun() -> {ok, I} = wasm:instantiate(M, Im), wasm:destroy(I) end);

%%% ------------------------------------------------------- embedding ---
run(worker) ->
    {ok, M} = wasm:compile(fac()), {ok, I} = wasm:instantiate(M, #{}),
    bench("inline call", 100000, fun() -> wasm:call(I, ~"fac-rec", [10]) end),
    Srv = spawn_link(fun() -> srv(I) end),
    bench("call via process round trip", 100000,
          fun() -> Srv ! {self(), go}, receive {ok, R} -> R end end);

%%% ----------------------------------------------------- concurrency ---
run(concurrency) ->
    {ok, M} = wasm:compile(fac()),
    io:format("schedulers online: ~p\n", [erlang:system_info(schedulers_online)]),
    [begin
         Ws = [spawn_worker(M) || _ <- lists:seq(1, N)],
         T = par(Ws, 20000),
         io:format("workers=~2w\ttotal-calls/s\t~.1f\n", [N, N * 20000 / (T / 1000000)]),
         [W ! stop || W <- Ws]
     end || N <- [1, 2, 4, 8, 14, 28]].

%% One memory per round, grown a page at a time, so the round trip is measured
%% and not the allocation of a large chunk. The memory is released between
%% rounds or the node's budget would be the thing under test.
%% Kept short on purpose. Each grow appends a chunk and rebuilds the chunk
%% tuple, so a long run measures the O(n) rebuild rather than the round trip
%% this arm exists to price.
-define(GROWS, 200).

grow_arm(Name, Wat, Kind) ->
    Ts = [begin
              Mem = fresh_memory(Wat, Kind),
              {T, _} = timer:tc(fun() -> grow_loop(Mem, ?GROWS) end),
              release(Mem, Kind),
              T * 1000 / ?GROWS
          end || _ <- lists:seq(1, 5)],
    io:format("~s\t~.1f\n", [Name, lists:min(Ts)]).

grow_loop(_M, 0) -> ok;
grow_loop(M, N) -> {ok, _, M2} = wasm_memory:grow(M, 1), grow_loop(M2, N - 1).

%% The exported arm goes through an instance, because that is the memory two
%% modules can be linked over and so the one whose growth two agents can race.
fresh_memory(_Wat, standalone) -> {ok, M} = wasm_memory:new(1, 4096), M;
fresh_memory(Wat, exported) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, Mod} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(Mod, #{}),
    {ok, Mem} = wasm:extern(I, ~"m"),
    put(inst, I),
    Mem.

release(Mem, standalone) -> wasm_memory:free(Mem);
release(_Mem, exported) -> wasm:destroy(get(inst)).

gc_module() -> ~"""
(module
  (type $s (struct (field $v (mut i32))))
  (func (export "add") (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 1)))
  (func (export "alloc") (param i32) (result i32)
    (struct.get $s $v (struct.new $s (local.get 0)))))
""".

gc_instance() -> gc_instance(undefined).
gc_instance(Link) ->
    {ok, P} = wasm_wat:module(gc_module()),
    {ok, M} = wasm_validate:module(P),
    Opts = case Link of
               undefined -> #{};
               Inst -> #{link => Inst}
           end,
    wasm:instantiate(M, #{}, Opts).

spawn_worker(M) ->
    spawn(fun() -> {ok, I} = wasm:instantiate(M, #{}), wloop(I) end).
wloop(I) ->
    receive
        {From, Ref, K} -> _ = [wasm:call(I, ~"fac-rec", [10]) || _ <- lists:seq(1, K)],
                          From ! {done, Ref}, wloop(I);
        stop -> ok
    end.
par(Ws, K) ->
    Ref = make_ref(), Self = self(),
    {T, _} = timer:tc(fun() ->
        [W ! {Self, Ref, K} || W <- Ws],
        [receive {done, Ref} -> ok end || _ <- Ws]
    end),
    T.

srv(I) ->
    receive {From, go} -> From ! {ok, wasm:call(I, ~"fac-rec", [10])}, srv(I) end.
