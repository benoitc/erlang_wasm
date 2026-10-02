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
     two_memories_each_with_an_image].

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
