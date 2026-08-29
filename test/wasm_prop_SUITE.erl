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

-define(NUMTESTS, 500).

all() ->
    [decode_is_total, decode_creates_no_atoms, wasi_creates_no_atoms,
     mutation_is_total, memory_matches_model, leb128_roundtrip].

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
