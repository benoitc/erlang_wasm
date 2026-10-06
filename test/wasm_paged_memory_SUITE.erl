%% Linear memory over a shared image: a page of the image is read in place
%% until something writes it, and the first write gives the memory a private
%% copy of that page and nothing more.
%%
%% Every case here builds its memory with the `image' memory option, which only
%% a test build accepts (`wasm_instance:memory_extra/1'). A restore is not
%% involved: what is under test is the representation and every path that reads
%% or writes it.
-module(wasm_paged_memory_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").
-include("wasm_exec.hrl").

-define(PAGE, 65536).

all() ->
    [an_untouched_image_reads_in_place,
     a_write_makes_one_page_private,
     reads_never_make_a_page_private,
     a_straddling_store_crosses_two_pages,
     bulk_writes_cross_pages,
     the_arena_grows_past_its_first_chunk,
     growth_appends_after_the_image,
     an_empty_image_is_a_plain_memory,
     a_stale_handle_reads_every_value,
     a_handle_from_before_another_holders_growth_reads_it,
     concurrent_first_writes_publish_one_slot,
     the_interpreter_agrees_with_a_flat_memory,
     generated_code_agrees_with_a_flat_memory,
     a_private_memory_grows_from_an_image,
     atomics_and_waits_on_an_image,
     two_memories_each_with_an_image,
     a_cached_translation_never_hides_a_later_write,
     an_unused_access_result_never_clobbers_a_used_one,
     writes_outside_generated_code_keep_its_reads_inline,
     an_untouched_page_reads_every_width_in_place].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% -------------------------------------------------------------- helpers ---

%% `N' pages, each either zero or a pattern seeded by its index, so a page
%% that is not zero is recognisably its own.
image_bin(Pages) ->
    << <<(page_bin(P))/binary>> || P <- lists:seq(0, Pages - 1) >>.

page_bin(P) when P rem 3 =:= 1 ->
    binary:copy(<<0>>, ?PAGE);
page_bin(P) ->
    << <<((P * 7 + I) band 16#FF)>> || I <- lists:seq(0, ?PAGE - 1) >>.

paged(Bin) -> paged(Bin, byte_size(Bin) div ?PAGE + 4).

paged(Bin, Max) ->
    Pages = byte_size(Bin) div ?PAGE,
    {ok, M} = wasm_memory:create(#limits{min = Pages, max = Max},
                                 #{image => wasm_memory:image_of(Bin),
                                   observable => true}),
    M.

%%% ---------------------------------------------------------------- reads ---

an_untouched_image_reads_in_place(_Config) ->
    Bin = image_bin(4),
    M = paged(Bin),
    ?assertEqual(Bin, wasm_memory:to_binary(M)),
    ?assertEqual(binary:part(Bin, 70000, 3), wasm_memory:load_bytes(M, 70000, 3)),
    <<_:131071/binary, W:64/little, _/binary>> = Bin,
    ?assertEqual(W, wasm_memory:load(M, 131071, 8)),
    ?assertEqual({0, 0}, wasm_memory:faults(M)),
    ok = wasm_memory:free(M).

%%% --------------------------------------------------------------- writes ---

%% One byte written makes exactly one 4 KiB page private, and the rest of the
%% image still reads as it was.
a_write_makes_one_page_private(_Config) ->
    Bin = image_bin(4),
    M = paged(Bin),
    ok = wasm_memory:store(M, 5000, 1, 16#AB),
    ?assertEqual({1, 1}, wasm_memory:faults(M)),
    ok = wasm_memory:store(M, 5001, 1, 16#CD),
    ok = wasm_memory:store(M, 70000, 4, 16#01020304),
    ok = wasm_memory:store(M, 200000, 8, -1),
    ?assertEqual({3, 3}, wasm_memory:faults(M)),
    Want = lists:foldl(fun({A, B}, Acc) -> put_bytes(Acc, A, B) end, Bin,
                       [{5000, <<16#AB, 16#CD>>},
                        {70000, <<16#01020304:32/little>>},
                        {200000, <<-1:64>>}]),
    ?assertEqual(Want, wasm_memory:to_binary(M)),
    ok = wasm_memory:free(M).

%% A load, a compare-exchange that does not match, and an exchange that writes
%% back the value already there are reads, and copy nothing.
reads_never_make_a_page_private(_Config) ->
    M = paged(image_bin(2)),
    _ = wasm_memory:load(M, 100, 4),
    _ = wasm_memory:load_bytes(M, 0, 2 * ?PAGE),
    _ = wasm_memory:atomic_load(M, 8, 8),
    Old = wasm_memory:atomic_load(M, 16, 4),
    ?assertEqual(Old, wasm_memory:atomic_cmpxchg(M, 16, 4, Old + 1, 7)),
    ?assertEqual(Old, wasm_memory:atomic_rmw(M, 16, 4, 'or', 0)),
    ?assertEqual({0, 0}, wasm_memory:faults(M)),
    ok = wasm_memory:free(M).

a_straddling_store_crosses_two_pages(_Config) ->
    Bin = image_bin(2),
    M = paged(Bin),
    ok = wasm_memory:store(M, 4093, 8, 16#1122334455667788),
    ?assertEqual({2, 2}, wasm_memory:faults(M)),
    ?assertEqual(16#1122334455667788, wasm_memory:load(M, 4093, 8)),
    ?assertEqual(put_bytes(Bin, 4093, <<16#1122334455667788:64/little>>),
                 wasm_memory:to_binary(M)),
    ok = wasm_memory:free(M).

bulk_writes_cross_pages(_Config) ->
    Bin = image_bin(4),
    M = paged(Bin),
    ok = wasm_memory:fill(M, 4000, 16#5A, 9000),
    ok = wasm_memory:copy(M, 70001, 3, 20000),
    ok = wasm_memory:copy(M, 140000, 140100, 6000),
    ok = wasm_memory:store_bytes(M, 190000, binary:copy(<<1, 2, 3>>, 3000)),
    W1 = put_bytes(Bin, 4000, binary:copy(<<16#5A>>, 9000)),
    W2 = put_bytes(W1, 70001, binary:part(W1, 3, 20000)),
    W3 = put_bytes(W2, 140000, binary:part(W2, 140100, 6000)),
    W4 = put_bytes(W3, 190000, binary:copy(<<1, 2, 3>>, 3000)),
    ?assertEqual(W4, wasm_memory:to_binary(M)),
    ok = wasm_memory:free(M).

%% More pages written than the first arena chunk holds: the arena grows, and
%% a handle that writes keeps reading what it wrote through it.
the_arena_grows_past_its_first_chunk(_Config) ->
    Bin = image_bin(8),
    M = paged(Bin),
    Addrs = [P * 4096 + 7 || P <- lists:seq(0, 8 * 16 - 1)],
    [ok = wasm_memory:store(M, A, 1, A band 16#FF) || A <- Addrs],
    ?assertEqual({128, 128}, wasm_memory:faults(M)),
    Want = lists:foldl(fun(A, Acc) -> put_bytes(Acc, A, <<(A band 16#FF)>>) end,
                       Bin, Addrs),
    ?assertEqual(Want, wasm_memory:to_binary(M)),
    ok = wasm_memory:free(M).

%%% --------------------------------------------------------------- growth ---

growth_appends_after_the_image(_Config) ->
    Bin = image_bin(2),
    M = paged(Bin),
    {ok, 2, M1} = wasm_memory:grow(M, 1),
    ok = wasm_memory:store(M1, 2 * ?PAGE + 10, 2, 16#BEEF),
    ok = wasm_memory:store(M1, 2 * ?PAGE - 1, 2, 16#7766),
    Want0 = <<Bin/binary, 0:(?PAGE * 8)>>,
    Want = put_bytes(put_bytes(Want0, 2 * ?PAGE + 10, <<16#BEEF:16/little>>),
                     2 * ?PAGE - 1, <<16#7766:16/little>>),
    ?assertEqual(Want, wasm_memory:to_binary(M1)),
    ok = wasm_memory:free(M1).

an_empty_image_is_a_plain_memory(_Config) ->
    {ok, M} = wasm_memory:create(#limits{min = 0, max = 4},
                                 #{image => wasm_memory:image_of(<<>>)}),
    ?assertEqual({0, 0}, wasm_memory:faults(M)),
    {ok, 0, M1} = wasm_memory:grow(M, 0),
    {ok, 0, M2} = wasm_memory:grow(M1, 1),
    ok = wasm_memory:store(M2, 100, 4, 42),
    ?assertEqual(42, wasm_memory:load(M2, 100, 4)),
    ?assertEqual({0, 0}, wasm_memory:faults(M2)),
    ok = wasm_memory:free(M2).

%%% --------------------------------------------------------- stale handles ---

%% A copy of the handle taken before any write sees every later write, through
%% arena chunks it never heard of.
a_stale_handle_reads_every_value(_Config) ->
    Bin = image_bin(8),
    Old = paged(Bin),
    New = write_many(Old, [P * 4096 + 3 || P <- lists:seq(0, 127)]),
    [?assertEqual((P * 4096 + 3) band 16#FF, wasm_memory:load(Old, P * 4096 + 3, 1))
     || P <- lists:seq(0, 127)],
    ?assertEqual(wasm_memory:to_binary(New), wasm_memory:to_binary(Old)),
    ok = wasm_memory:free(Old).

%% Writes through `store_r', taking every refreshed handle, as a store path
%% that keeps its handle does.
write_many(M, Addrs) ->
    lists:foldl(fun(A, H) ->
                        case wasm_memory:store_r(H, A, 1, A band 16#FF) of
                            ok -> H;
                            {refresh, H1} -> H1
                        end
                end, M, Addrs).

a_handle_from_before_another_holders_growth_reads_it(_Config) ->
    M = paged(image_bin(2)),
    {ok, 2, Grown} = wasm_memory:grow(M, 2),
    ok = wasm_memory:store(Grown, 3 * ?PAGE + 5, 1, 9),
    ?assertEqual(9, wasm_memory:load(M, 3 * ?PAGE + 5, 1)),
    ok = wasm_memory:free(M).

%%% ----------------------------------------------------------- concurrency ---

%% Writers that all reach the same untouched page hold between filling their
%% slot and publishing it, then all go: one slot is published, every other is
%% abandoned, and every write lands.
concurrent_first_writes_publish_one_slot(_Config) ->
    N = 8,
    M = paged(image_bin(1)),
    Self = self(),
    Pids = [spawn_link(
              fun() ->
                      put({wasm_memory, fault_hook},
                          fun(fault) ->
                                  Self ! {held, self()},
                                  receive go -> ok end
                          end),
                      _ = wasm_memory:atomic_rmw(M, 40, 4, add, 1),
                      Self ! {done, self()}
              end) || _ <- lists:seq(1, N)],
    [receive {held, P} -> ok end || P <- Pids],
    [P ! go || P <- Pids],
    [receive {done, P} -> ok end || P <- Pids],
    <<_:40/binary, Before:32/little, _/binary>> = image_bin(1),
    ?assertEqual((Before + N) band 16#FFFFFFFF, wasm_memory:load(M, 40, 4)),
    ?assertEqual({N, 1}, wasm_memory:faults(M)),
    ok = wasm_memory:free(M).

%%% ------------------------------------------------------------ instances ---

%% One function per access width, plus fill, copy, grow and a vector store,
%% over a memory the test lays an image under.
scribe_wat() -> ~"(module
  (memory (export \"m\") 1 16)
  (func (export \"st8\") (param i32 i32) local.get 0 local.get 1 i32.store8)
  (func (export \"st16\") (param i32 i32) local.get 0 local.get 1 i32.store16)
  (func (export \"st32\") (param i32 i32) local.get 0 local.get 1 i32.store)
  (func (export \"st64\") (param i32 i64) local.get 0 local.get 1 i64.store)
  (func (export \"ld8\") (param i32) (result i32) local.get 0 i32.load8_u)
  (func (export \"ld16\") (param i32) (result i32) local.get 0 i32.load16_u)
  (func (export \"ld32\") (param i32) (result i32) local.get 0 i32.load)
  (func (export \"ld64\") (param i32) (result i64) local.get 0 i64.load)
  (func (export \"fill\") (param i32 i32 i32)
    local.get 0 local.get 1 local.get 2 memory.fill)
  (func (export \"copy\") (param i32 i32 i32)
    local.get 0 local.get 1 local.get 2 memory.copy)
  (func (export \"grow\") (result i32) i32.const 1 memory.grow)
  (func (export \"vec\") (param i32 i32)
    local.get 0 local.get 1 i32x4.splat v128.store))".

instance(Bin, Extra) ->
    {ok, H} = wasm:compile({wat, scribe_wat()}),
    Opts = Extra#{fuel => infinity,
                  memory_opts => #{0 => #{image => wasm_memory:image_of(Bin)}}},
    {ok, I} = wasm:instantiate(H, #{}, Opts),
    {I, Opts}.

the_interpreter_agrees_with_a_flat_memory(_Config) ->
    agree(#{}, 400).

generated_code_agrees_with_a_flat_memory(_Config) ->
    ct:timetrap({minutes, 3}),
    agree(#{compile => true, compile_after => 1, compile_force => true}, 400).

%% Random accesses biased to page, chunk and region boundaries, each applied to
%% the instance and to a binary, and every load compared as it happens.
agree(Tier, Steps) ->
    rand:seed(exsss, {3, 5, 7}),
    Bin = image_bin(4),
    {I, Opts} = instance(Bin, Tier),
    Compiled = maps:is_key(compile, Tier),
    Warm = warm(Compiled, I, Opts, Bin),
    Model = lists:foldl(fun(_, Mod) -> step(I, Opts, Mod, Compiled) end, Warm,
                        lists:seq(1, Steps)),
    {ok, Pages} = wasm:memory_size(I),
    ?assertEqual(byte_size(Model), Pages * ?PAGE),
    ?assertEqual({ok, Model}, wasm:read_memory(I, 0, byte_size(Model))),
    ok = wasm:destroy(I).

step(I, Opts, Model, Compiled) ->
    Size = byte_size(Model),
    case rand:uniform(12) of
        12 when Size < 8 * ?PAGE ->
            {ok, [_]} = wasm:call(I, ~"grow", [], Opts),
            <<Model/binary, 0:(?PAGE * 8)>>;
        K ->
            {Fn, W, Args, Effect} = op(min(K, 11), Size),
            Got = entered(Compiled, I,
                          fun() -> {Fn, wasm:call(I, Fn, Args, Opts)} end),
            case Effect of
                {load, A} ->
                    <<_:A/binary, V:(W * 8)/little, _/binary>> = Model,
                    ?assertEqual({Fn, {ok, [signed(Fn, V)]}}, Got),
                    Model;
                {write, A, Bytes} ->
                    ?assertEqual({Fn, {ok, []}}, Got),
                    put_bytes(Model, A, Bytes);
                {copy, D, S, Len} ->
                    ?assertEqual({Fn, {ok, []}}, Got),
                    put_bytes(Model, D, binary:part(Model, S, Len))
            end
    end.

op(K, Size) ->
    case K of
        1 -> A = addr(Size, 1), V = rand:uniform(256) - 1,
             {~"st8", 1, [A, V], {write, A, <<V>>}};
        2 -> A = addr(Size, 2), V = rand:uniform(65536) - 1,
             {~"st16", 2, [A, V], {write, A, <<V:16/little>>}};
        3 -> A = addr(Size, 4), V = rand:uniform(16#7FFFFFFF),
             {~"st32", 4, [A, V], {write, A, <<V:32/little>>}};
        4 -> A = addr(Size, 8), V = rand:uniform(16#7FFFFFFFFFFFFFFF),
             {~"st64", 8, [A, V], {write, A, <<V:64/little>>}};
        5 -> A = addr(Size, 1), {~"ld8", 1, [A], {load, A}};
        6 -> A = addr(Size, 2), {~"ld16", 2, [A], {load, A}};
        7 -> A = addr(Size, 4), {~"ld32", 4, [A], {load, A}};
        8 -> A = addr(Size, 8), {~"ld64", 8, [A], {load, A}};
        9 -> Len = rand:uniform(9000), A = addr(Size, Len), B = rand:uniform(256) - 1,
             {~"fill", 0, [A, B, Len], {write, A, binary:copy(<<B>>, Len)}};
        10 -> Len = rand:uniform(9000), D = addr(Size, Len), S = addr(Size, Len),
              {~"copy", 0, [D, S, Len], {copy, D, S, Len}};
        11 -> A = addr(Size, 16), V = rand:uniform(16#7FFFFFFF),
              {~"vec", 0, [A, V], {write, A, binary:copy(<<V:32/little>>, 4)}}
    end.

signed(F, V) when F =:= ~"ld32", V >= 16#80000000 -> V - 16#100000000;
signed(F, V) when F =:= ~"ld64", V >= 16#8000000000000000 ->
    V - 16#10000000000000000;
signed(_F, V) -> V.

%% Half the time near a 4 KiB, 64 KiB or region boundary, so that straddles
%% and crossings are common rather than rare.
addr(Size, Len) ->
    A = case rand:uniform(2) of
            1 -> rand:uniform(Size) - 1;
            2 -> B = 4096 * rand:uniform(Size div 4096),
                 B - 16 + rand:uniform(32)
        end,
    max(0, min(A, Size - Len)).

%% Every function called once, then the compiled module adopted, so the calls
%% that are checked are the ones generated code serves.
warm(false, _I, _Opts, Model) ->
    Model;
warm(true, I, Opts, Model) ->
    Warm = lists:foldl(
             fun(K, Mod) ->
                     {Fn, _W, Args, Effect} = op(K, byte_size(Mod)),
                     {ok, _} = wasm:call(I, Fn, Args, Opts),
                     apply_effect(Effect, Mod)
             end, Model, lists:seq(1, 11)),
    ok = wasm_jit:await(I, 120_000),
    Warm.

apply_effect({load, _A}, Model) -> Model;
apply_effect({write, A, Bytes}, Model) -> put_bytes(Model, A, Bytes);
apply_effect({copy, D, S, Len}, Model) ->
    put_bytes(Model, D, binary:part(Model, S, Len)).

%% A call that must enter generated code does: with this process traced, a
%% call into one of the instance's own generated functions is reported during
%% it. Generated modules carry no `module_info', so a trace is what sees them,
%% and the tracer is a process of its own: a process does not receive its own
%% call trace.
entered(false, _I, F) ->
    F();
entered(true, I, F) ->
    Mod = wasm_code_slots:slot_module(wasm_instance:code_slot(I)),
    _ = erlang:trace_pattern({Mod, '_', '_'}, true, [local]),
    Self = self(),
    Tracer = spawn_link(fun() -> collect(Self, Mod, false) end),
    1 = erlang:trace(self(), true, [call, {tracer, Tracer}]),
    R = try F() after erlang:trace(self(), false, [call]) end,
    Ref = erlang:trace_delivered(self()),
    receive {trace_delivered, _, Ref} -> ok end,
    Tracer ! {done, Self},
    Seen = receive {seen, Tracer, S} -> S end,
    ?assertEqual({entered, Mod, true}, {entered, Mod, Seen}),
    R.

collect(Owner, Mod, Seen) ->
    receive
        {trace, _, call, {Mod, F, _}} ->
            collect(Owner, Mod,
                    Seen orelse lists:prefix("wasm_f_", atom_to_list(F)));
        {trace, _, call, _} -> collect(Owner, Mod, Seen);
        {done, Owner} -> Owner ! {seen, self(), Seen}
    end.

a_private_memory_grows_from_an_image(_Config) ->
    [grows(Tier) || Tier <- [#{}, #{compile => true, compile_after => 1,
                                    compile_force => true}]],
    ok.

grows(Tier) ->
    Bin = image_bin(2),
    {ok, H} = wasm:compile({wat, ~"(module (memory 1 8)
      (func (export \"grow\") (result i32) i32.const 2 memory.grow)
      (func (export \"st\") (param i32 i32) local.get 0 local.get 1 i32.store)
      (func (export \"ld\") (param i32) (result i32) local.get 0 i32.load))"}),
    Opts = Tier#{fuel => infinity,
                 memory_opts => #{0 => #{image => wasm_memory:image_of(Bin)}}},
    {ok, I} = wasm:instantiate(H, #{}, Opts),
    ?assertEqual({ok, [2]}, wasm:call(I, ~"grow", [], Opts)),
    ?assertEqual({ok, []}, wasm:call(I, ~"st", [3 * ?PAGE + 8, 77], Opts)),
    ?assertEqual({ok, [77]}, wasm:call(I, ~"ld", [3 * ?PAGE + 8], Opts)),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"ld", [3 * ?PAGE + 12], Opts)),
    <<_:100/binary, V:32/little-signed, _/binary>> = Bin,
    ?assertEqual({ok, [V]}, wasm:call(I, ~"ld", [100], Opts)),
    ?assertMatch({error, #{kind := out_of_bounds_memory_access}},
                 wasm:call(I, ~"ld", [4 * ?PAGE], Opts)),
    ok = wasm:destroy(I).

%%% ------------------------------------------------------- atomics, waits ---

%% Atomics are interpreted only: the compiler does not take them.
atomics_and_waits_on_an_image(_Config) ->
    Bin = image_bin(1),
    {ok, H} = wasm:compile({wat, ~"(module (memory 1 1 shared)
      (func (export \"add\") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.atomic.rmw.add)
      (func (export \"cas\") (param i32 i32 i32) (result i32)
        local.get 0 local.get 1 local.get 2 i32.atomic.rmw.cmpxchg)
      (func (export \"wait\") (param i32 i32) (result i32)
        local.get 0 local.get 1 i64.const 0 memory.atomic.wait32)
      (func (export \"notify\") (param i32) (result i32)
        local.get 0 i32.const 1 memory.atomic.notify))"}),
    Opts = #{fuel => infinity,
             memory_opts => #{0 => #{image => wasm_memory:image_of(Bin)}}},
    {ok, I} = wasm:instantiate(H, #{}, Opts),
    #mut{mems = {Mem}} = wasm_instance:mut(I),
    <<_:64/binary, Old:32/little, _/binary>> = Bin,
    Signed = fun(X) when X >= 16#80000000 -> X - 16#100000000; (X) -> X end,
    ?assertMatch({ok, [_]}, wasm:call(I, ~"cas", [64, Old + 1, 5], Opts)),
    ?assertEqual({ok, [1]}, wasm:call(I, ~"wait", [64, Old + 1], Opts)),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"notify", [64], Opts)),
    ?assertEqual({0, 0}, wasm_memory:faults(Mem)),
    ?assertEqual({ok, [Signed(Old)]}, wasm:call(I, ~"add", [64, 3], Opts)),
    ?assertEqual({1, 1}, wasm_memory:faults(Mem)),
    ?assertEqual({ok, [Signed((Old + 3) band 16#FFFFFFFF)]},
                 wasm:call(I, ~"cas", [64, (Old + 3) band 16#FFFFFFFF, 9], Opts)),
    ok = wasm:destroy(I).

two_memories_each_with_an_image(_Config) ->
    A = image_bin(1), B = image_bin(2),
    {ok, H} = wasm:compile({wat, ~"(module (memory 1) (memory 2)
      (func (export \"st\") (param i32 i32)
        local.get 0 local.get 1 i32.store 0
        local.get 0 local.get 1 i32.store 1)
      (func (export \"x\") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.copy 1 0))"}),
    Opts = #{fuel => infinity,
             memory_opts => #{0 => #{image => wasm_memory:image_of(A)},
                              1 => #{image => wasm_memory:image_of(B)}}},
    {ok, I} = wasm:instantiate(H, #{}, Opts),
    ?assertEqual({ok, []}, wasm:call(I, ~"st", [4094, 16#01020304], Opts)),
    ?assertEqual({ok, []}, wasm:call(I, ~"x", [70000, 100, 9000], Opts)),
    #mut{mems = {M0, M1}} = wasm_instance:mut(I),
    WantA = put_bytes(A, 4094, <<16#01020304:32/little>>),
    WantB0 = put_bytes(B, 4094, <<16#01020304:32/little>>),
    WantB = put_bytes(WantB0, 70000, binary:part(WantA, 100, 9000)),
    ?assertEqual(WantA, wasm_memory:to_binary(M0)),
    ?assertEqual(WantB, wasm_memory:to_binary(M1)),
    ok = wasm:destroy(I).

%%% ---------------------------------------------------------------- model ---

put_bytes(Model, Addr, Bin) ->
    Len = byte_size(Bin),
    <<Pre:Addr/binary, _:Len/binary, Post/binary>> = Model,
    <<Pre/binary, Bin/binary, Post/binary>>.

%%% ---------------------------------------------------- translation cache ---

%% Generated code caches the translation of a page it reached through an array,
%% and never one of an untouched image page. A compiled function that reads an
%% untouched page, has the host write that page through the memory handle
%% (making it private), and reads it again must see the host's write; and a
%% page it already reached privately and then grew past stays where it was.
a_cached_translation_never_hides_a_later_write(_Config) ->
    Bin = image_bin(2),
    {ok, M} = wasm:compile({wat, ~"(module
      (import \"h\" \"touch\" (func $touch))
      (memory (export \"m\") 2 8)
      (func (export \"f\") (result i32) (local i32)
        i32.const 5000 i32.load8_u local.set 0
        call $touch
        i32.const 5000 i32.load8_u
        local.get 0 i32.const 256 i32.mul i32.add)
      (func (export \"g\") (result i32)
        i32.const 6000 i32.const 7 i32.store8
        i32.const 1 memory.grow drop
        i32.const 6000 i32.load8_u))"}),
    Self = self(),
    Touch = fun(_Ctx, []) ->
                    Mem = persistent_term:get({?MODULE, mem}),
                    ok = wasm_memory:store(Mem, 5000, 1, 16#AB),
                    Self ! touched,
                    {ok, []}
            end,
    Opts = #{fuel => infinity, compile => true, compile_after => 1,
             compile_force => true,
             memory_opts => #{0 => #{image => wasm_memory:image_of(Bin)}}},
    {ok, I} = wasm:instantiate(M, #{{~"h", ~"touch"} => Touch}, Opts),
    persistent_term:put({?MODULE, mem}, mem(I)),
    {ok, _} = wasm:call(I, ~"g", [], Opts),
    ok = wasm_jit:await(I, 120_000),
    %% Rebuilt from the image so page 1 (5000) is untouched again.
    {ok, I2} = wasm:instantiate(M, #{{~"h", ~"touch"} => Touch}, Opts),
    persistent_term:put({?MODULE, mem}, mem(I2)),
    ok = wasm_jit:await(I2, 120_000),
    <<_:5000/binary, Before, _/binary>> = Bin,
    ?assertEqual({ok, [16#AB + Before * 256]},
                 entered(true, I2, fun() -> wasm:call(I2, ~"f", [], Opts) end)),
    receive touched -> ok end,
    ?assertEqual({ok, [7]},
                 entered(true, I2, fun() -> wasm:call(I2, ~"g", [], Opts) end)),
    persistent_term:erase({?MODULE, mem}),
    ok = wasm:destroy(I), ok = wasm:destroy(I2).

mem(I) ->
    #mut{mems = {M}} = wasm_instance:mut(I),
    M.

%% An access to memory 0 answers its result and the translation cache, and
%% either can be unused afterwards: the cache after a function's last access,
%% the result of a load that is dropped. With `no_ssa_opt' (the `baseline'
%% quality) OTP 29 lets an unused value of a multi-value `let' overwrite a used
%% one bound before it, so each shape is run under both qualities and checked
%% against the interpreter. The cache has two entries, so the shapes include
%% two pages taking turns, a third evicting one, and dead results at the end.
an_unused_access_result_never_clobbers_a_used_one(_Config) ->
    ct:timetrap({minutes, 3}),
    %% One module per quality: the compiled code is shared by every instance of
    %% the same module, so a second quality over the same bytes would run the
    %% first one's code.
    Module = fun(Q) ->
                     {ok, M} = wasm:compile({wat, <<(clobber_wat())/binary,
                                                    "(func (export \"",
                                                    (atom_to_binary(Q))/binary,
                                                    "\")))">>}),
                     M
             end,
    %% Each sequence on an instance of its own, so a shape that corrupts the
    %% state cannot hide behind the one before it.
    Seqs = [[{~"st", [64, 16#12345678]}, {~"ld", [64]}],
            [{~"st", [70000, 7]}],
            [{~"ld", [68]}],
            [{~"ld", [70000]}],
            [{~"stld", [72, 16#7EADBEEF]}],
            [{~"dropld", [64]}],
            [{~"dropld", [70000]}],
            [{~"ldtrap", [68, 0]}],
            [{~"ldtrap", [68, 1]}],
            [{~"ldmixed", [64, 0]}],
            [{~"ldmixed", [64, 1]}],
            [{~"sttrap", [80, 5]}, {~"ld", [80]}],
            [{~"stcall", [84, 300]}],
            [{~"ldcall", [64]}],
            [{~"ldcall2", [64]}],
            [{~"ldcalltrap", [64]}],
            [{~"dropblock", [64]}],
            [{~"dropblock", [70000]}],
            [{~"filltrap", [64]}],
            %% Two pages taking turns, and a third evicting one of them:
            %% within one array, and across the arrays growth adds.
            [{~"alt", [64, 4104]}],
            [{~"alt", [4104, 4104]}],
            [{~"grow", []}, {~"alt", [64, 65544]}],
            [{~"evict", [64, 4104, 8208]}],
            [{~"grow", []}, {~"evict", [64, 65544, 131088]}],
            [{~"grow", []}, {~"evict", [131088, 64, 131088]}],
            [{~"grow", []}, {~"altst", [72, 65552, 131096]}, {~"ld", [72]}],
            [{~"altdrop", [64, 4104]}],
            [{~"altdrop", [64, 70000]}],
            [{~"grow", []}, {~"altloop", [64, 65544, 131088, 7]}],
            [{~"grow", []}, {~"altmixed", [64, 65544, 0]}],
            [{~"grow", []}, {~"altmixed", [64, 65544, 1]}],
            [{~"grow", []}, {~"alttrap", [64, 65544, 0]}],
            [{~"grow", []}, {~"alttrap", [64, 65544, 1]}],
            [{~"grow", []}, {~"altcall", [64, 65544]}]],
    Run = fun(Q, Extra) ->
                  M = Module(Q),
                  Opts = Extra#{fuel => infinity},
                  Compiled = maps:is_key(compile, Extra),
                  case Compiled of
                      true ->
                          {ok, I} = wasm:instantiate(M, #{}, Opts),
                          _ = [wasm:call(I, F, A, Opts)
                               || Seq <- Seqs, {F, A} <- Seq],
                          ok = wasm_jit:await(I, 120_000),
                          ok = wasm:destroy(I);
                      false ->
                          ok
                  end,
                  [begin
                       {ok, I0} = wasm:instantiate(M, #{}, Opts),
                       ok = settle(Compiled, I0),
                       answers(Compiled, I0, Opts, Seq)
                   end || Seq <- Seqs]
          end,
    Want = Run(interpreted, #{}),
    [?assertEqual({Q, Want},
                  {Q, Run(Q, #{compile => true, compile_after => 1,
                               compile_force => true, compile_quality => Q})})
     || Q <- [full, baseline]],
    ok.

clobber_wat() ->
    ~"(module
      (memory (export \"m\") 1)
      (data (i32.const 64) \"\\01\\02\\03\\04\\05\\06\\07\\08\\09\\0a\\0b\\0c\")
      (func (export \"st\") (param i32 i32)
        local.get 0 local.get 1 i32.store)
      (func (export \"ld\") (param i32) (result i32)
        local.get 0 i32.load)
      (func (export \"stld\") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.store
        local.get 0 i32.const 4 i32.add i32.load)
      (func (export \"dropld\") (param i32) (result i32)
        local.get 0 i32.load drop
        local.get 0 i32.const 4 i32.add i32.load)
      (func (export \"ldtrap\") (param i32 i32) (result i32) (local i32)
        local.get 0 i32.load local.set 2
        local.get 1 if unreachable end
        local.get 2)
      (func (export \"ldmixed\") (param i32 i32) (result i32) (local i32)
        local.get 0 i32.load local.set 2
        local.get 1 i32.eqz if local.get 2 return end
        local.get 2 local.get 0 i32.const 4 i32.add i32.load i32.add)
      (func (export \"sttrap\") (param i32 i32)
        local.get 0 local.get 1 i32.store unreachable)
      (func $peek (param i32) (result i32)
        local.get 0 i32.load8_u)
      (func (export \"stcall\") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.store
        local.get 0 call $peek)
      (func (export \"ldcall\") (param i32) (result i32)
        local.get 0 i32.load call $peek)
      (func (export \"ldcall2\") (param i32) (result i32)
        local.get 0 i32.load
        local.get 0 i32.const 4 i32.add i32.load
        call $two)
      (func (export \"ldcalltrap\") (param i32)
        local.get 0 i32.load call $peek drop unreachable)
      (func (export \"dropblock\") (param i32) (result i32)
        block
          local.get 0 i32.const 4 i32.add i32.load drop
        end
        local.get 0 i32.load)
      (func (export \"filltrap\") (param i32)
        i32.const 96 local.get 0 i32.load i32.const 4 memory.fill
        unreachable)
      (func $two (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.sub)
      (func (export \"grow\") (result i32)
        i32.const 2 memory.grow
        i32.const 65544 i32.const 65544 i32.store
        i32.const 131088 i32.const 131088 i32.store
        i32.const 65552 i32.const 7 i32.store)
      (func (export \"alt\") (param i32 i32) (result i32)
        local.get 0 i32.load
        local.get 1 i32.load i32.add
        local.get 0 i32.const 4 i32.add i32.load i32.add
        local.get 1 i32.const 4 i32.add i32.load i32.add
        local.get 0 i32.load8_u i32.add)
      (func (export \"evict\") (param i32 i32 i32) (result i32)
        local.get 0 i32.load
        local.get 1 i32.load i32.sub
        local.get 2 i32.load i32.add
        local.get 0 i32.load8_u i32.sub
        local.get 1 i32.load16_u i32.add
        local.get 2 i32.load8_s i32.add
        local.get 1 i32.load i32.add)
      (func (export \"altst\") (param i32 i32 i32) (result i32)
        local.get 0 i32.const 11 i32.store
        local.get 1 i32.const 22 i32.store
        local.get 0 i32.load
        local.get 2 i32.const 33 i32.store
        local.get 1 i32.load i32.add
        local.get 0 local.get 2 i32.load i32.store
        local.get 0 i32.load i32.add)
      (func (export \"altdrop\") (param i32 i32) (result i32) (local i32)
        local.get 0 i32.load local.set 2
        local.get 1 i32.load drop
        local.get 0 i32.const 4 i32.add i32.load drop
        local.get 1 i32.const 4 i32.add i32.load drop
        local.get 2)
      (func (export \"altloop\") (param i32 i32 i32 i32) (result i32)
        (local i32)
        loop
          local.get 4
          local.get 0 i32.load i32.add
          local.get 1 i32.load i32.add
          local.get 2 i32.load8_u i32.add
          local.set 4
          local.get 0 local.get 4 i32.store
          local.get 3 i32.const 1 i32.sub local.tee 3
          br_if 0
        end
        local.get 4 local.get 1 i32.load i32.add)
      (func (export \"altmixed\") (param i32 i32 i32) (result i32)
        (local i32)
        local.get 0 i32.load
        local.get 1 i32.load i32.add local.set 3
        local.get 2 i32.eqz if local.get 3 return end
        local.get 3 local.get 0 i32.const 4 i32.add i32.load i32.add)
      (func (export \"alttrap\") (param i32 i32 i32) (result i32)
        (local i32)
        local.get 0 i32.load
        local.get 1 i32.load i32.add local.set 3
        local.get 2 if unreachable end
        local.get 3)
      (func (export \"altcall\") (param i32 i32) (result i32)
        local.get 0 i32.load
        local.get 1 i32.load
        call $two
        local.get 0 i32.load8_u
        call $peek i32.add)".

settle(false, _I) -> ok;
settle(true, I) -> wasm_jit:await(I, 120_000).

answers(Compiled, I, Opts, Calls) ->
    Rs = [{F, A, entered(Compiled, I, fun() -> outcome(wasm:call(I, F, A, Opts))
                                      end)}
          || {F, A} <- Calls],
    Mem = wasm:read_memory(I, 0, 128),
    _ = wasm:destroy(I),
    {Rs, Mem}.

outcome({ok, _} = R) -> R;
outcome({error, #{class := C, kind := K}}) -> {error, C, K};
outcome(Other) -> Other.

%%% ------------------------------------------------- handles kept current ---

%% A write that is not a plain store can publish arena chunks: a host
%% function's, `wasm:write_memory/3' between two calls, a `memory.fill'. The
%% handle generated code reads through has to see them, or every later read of
%% a page in those chunks leaves the inline path for `wasm_exec:load_at/5'.
%% Ten reads of ten pages the write made private call it not once, under
%% either quality, each with a module of its own as in the case above.
writes_outside_generated_code_keep_its_reads_inline(_Config) ->
    ct:timetrap({minutes, 3}),
    [ok = inline_reads(Q) || Q <- [full, baseline]],
    ok.

inline_reads(Q) ->
    Bin = image_bin(2),
    {ok, M} = wasm:compile({wat, <<"(module
      (import \"h\" \"touch\" (func $touch))
      (memory (export \"m\") 2 8)
      (func $read (export \"read\") (result i32)
        i32.const 0
        i32.const 8 i32.load8_u i32.add
        i32.const 4104 i32.load8_u i32.add
        i32.const 8200 i32.load8_u i32.add
        i32.const 12296 i32.load8_u i32.add
        i32.const 16392 i32.load8_u i32.add
        i32.const 20488 i32.load8_u i32.add
        i32.const 24584 i32.load8_u i32.add
        i32.const 28680 i32.load8_u i32.add
        i32.const 32776 i32.load8_u i32.add
        i32.const 36872 i32.load8_u i32.add
      )
      (func (export \"f\") (result i32) call $touch call $read)
      (func (export \"g\") (result i32)
        i32.const 0 i32.const 1 i32.const 40960 memory.fill call $read)
      (func (export \"", (atom_to_binary(Q))/binary, "\")))">>}),
    Touch = fun(Ctx, []) -> ok = touch(Ctx), {ok, []} end,
    Opts = #{fuel => infinity, compile => true, compile_after => 1,
             compile_force => true, compile_quality => Q,
             memory_opts => #{0 => #{image => wasm_memory:image_of(Bin)}}},
    New = fun() ->
                  {ok, I} = wasm:instantiate(M, #{{~"h", ~"touch"} => Touch},
                                             Opts),
                  I
          end,
    I0 = New(),
    {ok, _} = wasm:call(I0, ~"f", [], Opts),
    {ok, _} = wasm:call(I0, ~"read", [], Opts),
    {ok, _} = wasm:call(I0, ~"g", [], Opts),
    ok = wasm_jit:await(I0, 120_000),
    Want = lists:sum([binary:at(Bin, 4096 * K + 8) bxor 16#FF
                      || K <- lists:seq(0, 9)]),
    %% Through a host function, during a call.
    I1 = New(),
    ok = wasm_jit:await(I1, 120_000),
    ?assertEqual({{ok, [Want]}, 0}, load_at_calls(I1, ~"f", Opts)),
    %% From outside, before one.
    I2 = New(),
    ok = wasm_jit:await(I2, 120_000),
    ok = touch(I2),
    ?assertEqual({{ok, [Want]}, 0}, load_at_calls(I2, ~"read", Opts)),
    %% By a bulk write in generated code.
    I3 = New(),
    ok = wasm_jit:await(I3, 120_000),
    ?assertEqual({{ok, [10]}, 0}, load_at_calls(I3, ~"g", Opts)),
    [ok = wasm:destroy(I) || I <- [I0, I1, I2, I3]],
    ok.

%% Ten pages written, one byte each: one arena chunk published.
touch(Ctx) ->
    lists:foreach(
      fun(K) ->
              A = 4096 * K + 8,
              {ok, <<B>>} = wasm:read_memory(Ctx, A, 1),
              ok = wasm:write_memory(Ctx, A, <<(B bxor 16#FF)>>)
      end, lists:seq(0, 9)).

load_at_calls(I, F, Opts) ->
    MFA = {wasm_exec, load_at, 5},
    _ = erlang:trace_pattern(MFA, true, [call_count]),
    try
        R = entered(true, I, fun() -> wasm:call(I, F, [], Opts) end),
        {call_count, N} = erlang:trace_info(MFA, call_count),
        {R, N}
    after
        erlang:trace_pattern(MFA, false, [call_count])
    end.

%%% ------------------------------------------- reads from untouched pages ---

%% Generated code reads an untouched image page by matching the access's own
%% bytes out of the page binary, signed or not per load. Every load at every
%% offset 0..15 of a page of 0xFF, a page of mixed bytes and a page of zeros
%% answers what the interpreter answers, under either quality. The offsets
%% that straddle a word go to the helper and are checked all the same.
an_untouched_page_reads_every_width_in_place(_Config) ->
    ct:timetrap({minutes, 3}),
    Bin = <<(binary:copy(<<16#FF>>, ?PAGE))/binary,
            << <<((I * 37 + 11) band 16#FF)>>
               || I <- lists:seq(0, ?PAGE - 1) >>/binary,
            0:(?PAGE * 8)>>,
    Calls = [{Op, [P * ?PAGE + Off]}
             || Op <- width_loads(), P <- [0, 1, 2], Off <- lists:seq(0, 15)],
    Run = fun(Q, Extra) ->
                  {ok, M} = wasm:compile({wat, width_wat(Q)}),
                  Opts = Extra#{fuel => infinity,
                                memory_opts =>
                                    #{0 => #{image =>
                                                 wasm_memory:image_of(Bin)}}},
                  Compiled = maps:is_key(compile, Extra),
                  case Compiled of
                      true ->
                          {ok, I0} = wasm:instantiate(M, #{}, Opts),
                          _ = [wasm:call(I0, F, [0], Opts)
                               || F <- width_loads()],
                          ok = wasm_jit:await(I0, 120_000),
                          ok = wasm:destroy(I0);
                      false ->
                          ok
                  end,
                  {ok, I} = wasm:instantiate(M, #{}, Opts),
                  ok = settle(Compiled, I),
                  MFA = {wasm_exec, load_at, 5},
                  _ = erlang:trace_pattern(MFA, true, [call_count]),
                  {Rs, Slow} =
                      try
                          {entered(Compiled, I,
                                   fun() ->
                                           [{F, A, wasm:call(I, F, A, Opts)}
                                            || {F, A} <- Calls]
                                   end),
                           element(2, erlang:trace_info(MFA, call_count))}
                      after
                          erlang:trace_pattern(MFA, false, [call_count])
                      end,
                  %% Only an access that straddles a word leaves the inline
                  %% path, and only in generated code.
                  ?assertEqual({Q, Compiled andalso straddles(Calls)},
                               {Q, Compiled andalso Slow}),
                  #mut{mems = {Mem}} = wasm_instance:mut(I),
                  ?assertEqual({0, 0}, wasm_memory:faults(Mem)),
                  ok = wasm:destroy(I),
                  Rs
          end,
    Want = Run(interpreted, #{}),
    [?assertEqual({Q, Want},
                  {Q, Run(Q, #{compile => true, compile_after => 1,
                               compile_force => true, compile_quality => Q})})
     || Q <- [full, baseline]],
    ok.

straddles(Calls) ->
    length([A || {Op, [A]} <- Calls, (A band 7) + width(Op) > 8]).

width(Op) ->
    case binary:split(Op, ~".load") of
        [T, <<>>] -> binary_to_integer(binary:part(T, 1, 2)) div 8;
        [_, Suffix] -> binary_to_integer(hd(binary:split(Suffix, ~"_"))) div 8
    end.

width_loads() ->
    [~"i32.load", ~"i32.load8_s", ~"i32.load8_u", ~"i32.load16_s",
     ~"i32.load16_u", ~"i64.load", ~"i64.load8_s", ~"i64.load8_u",
     ~"i64.load16_s", ~"i64.load16_u", ~"i64.load32_s", ~"i64.load32_u",
     ~"f32.load", ~"f64.load"].

width_wat(Q) ->
    Fns = [begin
               [T | _] = binary:split(Op, ~"."),
               <<"(func (export \"", Op/binary, "\") (param i32) (result ",
                 T/binary, ") local.get 0 ", Op/binary, ")\n">>
           end || Op <- width_loads()],
    iolist_to_binary(["(module (memory 3)\n", Fns,
                      "(func (export \"", atom_to_binary(Q), "\")))"]).
