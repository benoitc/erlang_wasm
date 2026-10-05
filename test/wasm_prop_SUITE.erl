%% @doc Property-based tests.
%%
%% Three properties matter more than the rest, because they are the ones that
%% hold the runtime's safety claims up:
%%
%% <ul>
%%   <li><b>Totality.</b> No binary, however hostile, produces anything but
%%       `{ok, _}' or a structured `{error, _}'. Not a crash, not a raw Erlang
%%       exception, not an exit. This is the property that makes it safe to
%%       hand the decoder untrusted input at all.</li>
%%   <li><b>No atom creation.</b> Neither decoding arbitrary input nor handing
%%       arbitrary strings across the WASI boundary may move the atom count.
%%       The atom table is node-wide and never reclaimed, so a single reachable
%%       `binary_to_atom' would be a remote node kill. Both halves are here
%%       because only the first used to be: `sock_getaddrinfo' resolved a
%%       guest-chosen service name through `binary_to_atom/2', so the property
%%       held for the decoder while the runtime had a hole next door.</li>
%%   <li><b>Memory equivalence.</b> Random sequences of load, store, fill, copy
%%       and grow against the `atomics' backend must agree byte for byte with a
%%       plain binary model. This is the property that will validate the
%%       optional native backend for free when it arrives.</li>
%% </ul>
-module(wasm_prop_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").
-include("wasm.hrl").

-define(NUMTESTS, 500).

all() ->
    [decode_is_total, decode_creates_no_atoms, wasi_creates_no_atoms,
     mutation_is_total, memory_matches_model, paged_memory_matches_model,
     leb128_roundtrip].

%%% --------------------------------------------------------------- totality ---

decode_is_total(_Config) ->
    run(?FORALL(Bin, binary(), is_total_result(wasm_decode:module(Bin)))).

%% Random bytes rarely reach past the header, so the interesting corpus is
%% *valid modules with one thing broken*. This is structure-aware fuzzing: it
%% gets the decoder deep into section parsing before anything goes wrong.
mutation_is_total(_Config) ->
    Seeds = seed_modules(),
    case Seeds of
        [] -> {skip, "no spec fixtures to mutate"};
        _ ->
            run(?FORALL({Seed, Muts}, {oneof(Seeds), list(mutation())},
                        begin
                            Bin = apply_mutations(Seed, Muts),
                            R = wasm_decode:module(Bin),
                            is_total_result(R) andalso validate_is_total(R)
                        end))
    end.

validate_is_total({error, _}) -> true;
validate_is_total({ok, M}) -> is_total_result(wasm_validate:module(M)).

is_total_result({ok, _}) -> true;
is_total_result({error, E}) -> wasm_error:is_error(E);
is_total_result(_) -> false.

decode_creates_no_atoms(_Config) ->
    %% Warm up first: the very first call loads modules, and loading a module
    %% interns its atoms, which would otherwise look like decoder behaviour.
    _ = wasm_decode:module(<<0, 16#61, 16#73, 16#6D, 1, 0, 0, 0>>),
    Seeds = seed_modules(),
    run(?FORALL({Seed, Muts}, {oneof([<<>> | Seeds]), list(mutation())},
                begin
                    Bin = apply_mutations(Seed, Muts),
                    Before = erlang:system_info(atom_count),
                    _ = wasm_decode:module(Bin),
                    erlang:system_info(atom_count) =:= Before
                end)).

%% The other half: strings a *guest* chooses, across the calls that take one.
%% A service name, a host name and a path, all arbitrary bytes, all reaching
%% the host through the real dispatch rather than through a helper called
%% directly.
%%
%% Two batches of distinct strings rather than one, because "the atom count did
%% not move" is not quite the property. Host libraries load modules the first
%% time a path through them is taken, and loading a module interns its atoms:
%% feeding `<<"5">>` as a service made `service_port/1` accept it as a port
%% number and `inet:getaddrs/2` resolve it, which loaded the resolver and added
%% 37 atoms at once. That is bounded and it is somebody else's.
%%
%% What must not happen is atoms *scaling with the number of distinct strings*.
%% So the first batch absorbs whatever loads on first use, and the second batch
%% of equally many, equally varied, entirely different strings must add
%% nothing at all.
wasi_creates_no_atoms(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Parsed} = wasm_wat:module(wasi_strings_module()),
    {ok, Mod} = wasm_validate:module(Parsed),
    Dir = filename:join(?config(priv_dir, Config), "atoms"),
    ok = filelib:ensure_path(Dir),
    Imports = wasi_preview1:imports(#{dirs => [{~"/d", Dir, read}],
                                      net => #{resolve => allow},
                                      random => strong}),
    {ok, I} = wasm:instantiate(Mod, Imports),

    ok = probe_batch(I, 1),
    Before = erlang:system_info(atom_count),
    ok = probe_batch(I, 2),
    After = erlang:system_info(atom_count),
    ok = wasm:destroy(I),
    ?assertEqual(Before, After).

%% Same shapes in both batches, different values, so a path reached in the
%% second was reached in the first.
probe_batch(I, Batch) ->
    lists:foreach(fun(K) -> [probe(I, S) || S <- shapes(Batch, K)] end,
                  lists:seq(1, 50)),
    ok.

shapes(Batch, K) ->
    N = integer_to_binary(Batch * 100000 + K),
    [N,                                        % taken as a port number
     <<"svc", N/binary>>,                      % a service name that is not one
     <<"host", N/binary, ".invalid">>,         % a name, and a path component
     <<"../", N/binary>>,                      % an escaping path
     crypto:strong_rand_bytes(8)].             % bytes that are no kind of string

%% One binary used as all three kinds of string, since what is under test is
%% the bytes reaching the host and not what any one call makes of them.
probe(I, Bin) ->
    Len = erlang:min(byte_size(Bin), 200),
    <<S:Len/binary, _/binary>> = Bin,
    ok = wasm:write_memory(I, 320, <<S/binary, 0>>),
    _ = wasm:call(I, ~"resolve", [Len]),
    _ = wasm:call(I, ~"open", [Len]),
    ok.

wasi_strings_module() -> ~"""
(module
  (import "wasi_snapshot_preview1" "sock_getaddrinfo"
    (func $gai (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 2)
  ;; The same bytes as a host name, as a service name, and as a path.
  (func (export "resolve") (param $len i32) (result i32)
    (call $gai (i32.const 320) (local.get $len)
               (i32.const 320) (local.get $len)
               (i32.const 288) (i32.const 160) (i32.const 1) (i32.const 4)))
  (func (export "open") (param $len i32) (result i32)
    (call $open (i32.const 3) (i32.const 0) (i32.const 320) (local.get $len)
                (i32.const 0) (i64.const 0) (i64.const 0) (i32.const 0)
                (i32.const 8))))
""".

%%% ----------------------------------------------------------------- memory ---

%% The reference model is a plain binary, rebuilt on every write. That is far
%% too slow to be a real implementation (1.2 us per store, measured) but it is
%% obviously correct, which is exactly what a model needs to be.
memory_matches_model(_Config) ->
    run(?FORALL(Ops, list(mem_op()),
                begin
                    {ok, Mem} = wasm_memory:new(2, 4),
                    Model = binary:copy(<<0>>, 2 * 65536),
                    {FinalMem, FinalModel} =
                        lists:foldl(fun apply_mem_op/2, {Mem, Model}, Ops),
                    wasm_memory:to_binary(FinalMem) =:= FinalModel
                end), 200).

mem_op() ->
    oneof([{store, addr(), width(), integer(0, 16#FFFFFFFFFFFFFFFF)},
           {fill, addr(), integer(0, 255), integer(0, 64)},
           {copy, addr(), addr(), integer(0, 64)},
           {store_bytes, addr(), binary()}]).

addr() -> integer(0, 2 * 65536 - 1).
width() -> oneof([1, 2, 4, 8]).

%% Operations that would trap are skipped rather than applied, so the model
%% only ever sees the in-bounds cases the real memory also accepts.
apply_mem_op({store, Addr, N, V}, {Mem, Model}) when Addr + N =< byte_size(Model) ->
    ok = wasm_memory:store(Mem, Addr, N, V),
    {Mem, model_write(Model, Addr, <<V:(N * 8)/little>>)};
apply_mem_op({fill, Addr, B, Len}, {Mem, Model}) when Addr + Len =< byte_size(Model) ->
    ok = wasm_memory:fill(Mem, Addr, B, Len),
    {Mem, model_write(Model, Addr, binary:copy(<<B>>, Len))};
apply_mem_op({copy, Dst, Src, Len}, {Mem, Model})
  when Dst + Len =< byte_size(Model), Src + Len =< byte_size(Model) ->
    ok = wasm_memory:copy(Mem, Dst, Src, Len),
    <<_:Src/binary, Slice:Len/binary, _/binary>> = Model,
    {Mem, model_write(Model, Dst, Slice)};
apply_mem_op({store_bytes, Addr, Bin}, {Mem, Model})
  when Addr + byte_size(Bin) =< byte_size(Model) ->
    ok = wasm_memory:store_bytes(Mem, Addr, Bin),
    {Mem, model_write(Model, Addr, Bin)};
apply_mem_op(_Skipped, State) ->
    State.

model_write(Model, Addr, Bin) ->
    Len = byte_size(Bin),
    <<Pre:Addr/binary, _:Len/binary, Post/binary>> = Model,
    <<Pre/binary, Bin/binary, Post/binary>>.

%% The same equivalence over a memory laid on an image, where a page is read in
%% place until a write copies it. The image is random, some of its pages zero;
%% addresses favour 4 KiB, 64 KiB and region boundaries, where a page or chunk
%% is crossed; and an out-of-bounds operation must trap, not be skipped. Half
%% the writes keep the refreshed handle a store may answer and half do not, so
%% stale handles read everything too.
paged_memory_matches_model(_Config) ->
    run(?FORALL({Pages, Seed, Ops},
                {integer(1, 3), integer(), list(paged_op())},
                begin
                    Bin = image(Pages, Seed),
                    {ok, Mem} = wasm_memory:create(
                                  #limits{min = Pages, max = Pages + 2},
                                  #{image => wasm_memory:image_of(Bin),
                                    observable => true}),
                    {Final, Model} = lists:foldl(fun paged_step/2, {Mem, Bin},
                                                 Ops),
                    Same = wasm_memory:to_binary(Final) =:= Model
                        andalso wasm_memory:to_binary(Mem) =:= Model,
                    ok = wasm_memory:free(Final),
                    Same
                end), 200).

image(Pages, Seed) ->
    rand:seed(exsss, {Seed, 1, 2}),
    << <<(case rand:uniform(3) of
              1 -> <<0:(65536 * 8)>>;
              _ -> rand:bytes(65536)
          end)/binary>> || _ <- lists:seq(1, Pages) >>.

paged_op() ->
    oneof([{store, paddr(), width(), integer(0, 16#FFFFFFFFFFFFFFFF), boolean()},
           {load, paddr(), width()},
           {fill, paddr(), integer(0, 255), integer(0, 9000)},
           {copy, paddr(), paddr(), integer(0, 9000)},
           {store_bytes, paddr(), binary(), boolean()},
           {load_bytes, paddr(), integer(0, 9000)},
           {rmw, paddr(), integer(0, 16#FFFFFFFF)},
           {grow}]).

%% Near a boundary most of the time; some past the end, to see the trap.
paddr() ->
    oneof([integer(0, 5 * 65536),
           ?LET({B, D}, {integer(1, 5 * 16), integer(-16, 16)},
                max(0, B * 4096 + D))]).

paged_step({store, A, N, V, Keep}, {M, Model}) ->
    in_bounds(A, N, Model,
              fun() ->
                      R = wasm_memory:store_r(M, A, N, V),
                      {keep(Keep, M, R), model_write(Model, A, <<V:(N * 8)/little>>)}
              end, {M, Model});
paged_step({load, A, N}, {M, Model}) ->
    in_bounds(A, N, Model,
              fun() ->
                      V = wasm_memory:load(M, A, N),
                      <<_:A/binary, V:(N * 8)/little, _/binary>> = Model,
                      {M, Model}
              end, {M, Model});
paged_step({fill, A, B, Len}, {M, Model}) ->
    in_bounds(A, Len, Model,
              fun() ->
                      ok = wasm_memory:fill(M, A, B, Len),
                      {M, model_write(Model, A, binary:copy(<<B>>, Len))}
              end, {M, Model});
paged_step({copy, D, S, Len}, {M, Model}) ->
    in_bounds(max(D, S), Len, Model,
              fun() ->
                      ok = wasm_memory:copy(M, D, S, Len),
                      {M, model_write(Model, D, binary:part(Model, S, Len))}
              end, {M, Model});
paged_step({store_bytes, A, Bin, _Keep}, {M, Model}) ->
    in_bounds(A, byte_size(Bin), Model,
              fun() ->
                      ok = wasm_memory:store_bytes(M, A, Bin),
                      {M, model_write(Model, A, Bin)}
              end, {M, Model});
paged_step({load_bytes, A, Len}, {M, Model}) ->
    in_bounds(A, Len, Model,
              fun() ->
                      Got = wasm_memory:load_bytes(M, A, Len),
                      Got = binary:part(Model, A, Len),
                      {M, Model}
              end, {M, Model});
paged_step({rmw, A0, V}, {M, Model}) ->
    A = A0 band (bnot 3),
    in_bounds(A, 4, Model,
              fun() ->
                      Old = wasm_memory:atomic_rmw(M, A, 4, add, V),
                      <<_:A/binary, Old:32/little, _/binary>> = Model,
                      New = (Old + V) band 16#FFFFFFFF,
                      {M, model_write(Model, A, <<New:32/little>>)}
              end, {M, Model});
paged_step({grow}, {M, Model}) ->
    case wasm_memory:grow(M, 1) of
        {ok, _, M1} -> {M1, <<Model/binary, 0:(65536 * 8)>>};
        {error, _} -> {M, Model}
    end.

keep(true, _M, {refresh, M1}) -> M1;
keep(_, M, _) -> M.

%% In bounds, the operation and the model move together. Out of bounds it must
%% trap, before the model is consulted, and change nothing.
in_bounds(A, Len, Model, Do, _State) when A + Len =< byte_size(Model) ->
    Do();
in_bounds(_A, _Len, _Model, Do, State) ->
    try Do() of
        _ -> error(no_trap)
    catch
        throw:{wasm_error, #{kind := out_of_bounds_memory_access}} -> State
    end.

%%% ---------------------------------------------------------------- leb128 ---

leb128_roundtrip(_Config) ->
    run(?FORALL(V, integer(0, 16#FFFFFFFF),
                {V, <<>>} =:= wasm_leb128:u32(wasm_leb128:encode_u32(V)))),
    run(?FORALL(V, integer(-16#80000000, 16#7FFFFFFF),
                {V, <<>>} =:= wasm_leb128:s32(wasm_leb128:encode_s32(V)))).

%%% -------------------------------------------------------------- generators ---

mutation() ->
    oneof([{flip_byte, non_neg_integer(), integer(0, 255)},
           {truncate, non_neg_integer()},
           {append, binary()},
           {splice, non_neg_integer(), binary()}]).

apply_mutations(Bin, Muts) -> lists:foldl(fun mutate/2, Bin, Muts).

mutate(_Mut, <<>>) -> <<>>;
mutate({flip_byte, Pos, Byte}, Bin) ->
    I = Pos rem byte_size(Bin),
    <<Pre:I/binary, _, Post/binary>> = Bin,
    <<Pre/binary, Byte, Post/binary>>;
mutate({truncate, N}, Bin) ->
    binary:part(Bin, 0, N rem (byte_size(Bin) + 1));
mutate({append, Extra}, Bin) ->
    <<Bin/binary, Extra/binary>>;
mutate({splice, Pos, Extra}, Bin) ->
    I = Pos rem byte_size(Bin),
    <<Pre:I/binary, Post/binary>> = Bin,
    <<Pre/binary, Extra/binary, Post/binary>>.

%% A handful of real modules, used as mutation seeds. Committed rather than
%% generated: a property that only runs where somebody has built fixtures is a
%% property that mostly does not run.
seed_modules() ->
    Dir = filename:join(wasm_spec_runner:fixtures_dir(), "seeds"),
    [B || F <- filelib:wildcard(filename:join(Dir, "*.wasm")),
          {ok, B} <- [file:read_file(F)]].

%%% ---------------------------------------------------------------- runner ---

run(Prop) -> run(Prop, ?NUMTESTS).

run(Prop, N) ->
    case proper:quickcheck(Prop, [{numtests, N}, {to_file, user}]) of
        true -> ok;
        Other -> ct:fail({property_failed, Other})
    end.
