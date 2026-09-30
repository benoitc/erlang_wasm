%% @doc What a decoded module keeps of its input.
%%
%% The decoder matches sub-binaries out of the input, and a sub-binary keeps
%% the whole binary it points into alive, off heap. A module that kept one
%% custom section or one data segment that way pinned the entire `.wasm' for
%% as long as the module lived: 31 MB for the CPython reactor, 23 MB of it
%% DWARF nobody reads. These cases build a module with a large `.debug_info'
%% section, drop the input, and ask what is still held.
%%
%% The module is built by hand rather than read from a fixture so that it runs
%% in CI, and it is built inside a child process that exits before anything is
%% measured, so the only reference left to the input is whatever the module
%% itself holds.
-module(wasm_decode_retain_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").

-define(MB, (1024 * 1024)).

all() ->
    [module_owns_its_bytes, dropped_input_is_released,
     cached_module_releases_input, kept_custom_sections].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

%%% ----------------------------------------------------------------- cases ---

%% Every binary in the module, whatever field it sits in, points only at its
%% own bytes. Names and segments are over 64 bytes so that none of them is a
%% heap binary by accident of size.
module_owns_its_bytes(_Config) ->
    M = compile_in_child(1 * ?MB),
    Bins = binaries(M),
    ?assert(length(Bins) >= 6),
    Pinning = [{byte_size(B), binary:referenced_byte_size(B)}
               || B <- Bins, binary:referenced_byte_size(B) > byte_size(B)],
    ?assertEqual([], Pinning),
    Referenced = lists:sum([binary:referenced_byte_size(B) || B <- Bins]),
    ?assert(Referenced < 4096).

%% The input's memory comes back once the module is the only thing left.
dropped_input_is_released(_Config) ->
    Before = binary_memory(),
    M = compile_in_child(16 * ?MB),
    Delta = binary_memory() - Before,
    ct:log("binary memory held with the module: ~p bytes", [Delta]),
    ?assert(Delta < 4 * ?MB),
    _ = id(M),
    ok.

%% The cache puts the module in `persistent_term', whose literal area would
%% keep a sub-binary's whole input alive until the entry is erased. What is
%% asked is what the cached entry itself references, and not the node's binary
%% memory, which every other process moves.
cached_module_releases_input(_Config) ->
    Parent = self(),
    Pid = spawn(fun() ->
                        {ok, H} = wasm:load(build(16 * ?MB)),
                        Parent ! {loaded, self(), H},
                        receive stop -> ok = wasm_module_cache:unload(H) end,
                        Parent ! {unloaded, self()}
                end),
    {wasm_module, Hash} =
        receive {loaded, Pid, Handle} -> Handle
        after 60000 -> ct:fail(load_timeout)
        end,
    Bins = binaries(persistent_term:get(?CACHED_MODULE_KEY(Hash))),
    Pid ! stop,
    receive {unloaded, Pid} -> ok after 60000 -> ct:fail(unload_timeout) end,
    ?assert(length(Bins) >= 6),
    Referenced = lists:sum([binary:referenced_byte_size(B) || B <- Bins]),
    ct:log("bytes the cached module references: ~p", [Referenced]),
    ?assert(Referenced < 4 * ?MB).

%% What is kept is kept whole; DWARF is not kept at all.
kept_custom_sections(_Config) ->
    #module{customs = Customs} = compile_in_child(1024),
    ?assertEqual([<<"name">>, <<"producers">>, <<"tool-data">>],
                 [N || {N, _} <- Customs]),
    ?assertEqual(binary:copy(<<"t">>, 100),
                 proplists:get_value(<<"tool-data">>, Customs)).

%%% --------------------------------------------------------------- helpers ---

compile_in_child(DebugBytes) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                           {ok, M} = wasm:compile(build(DebugBytes)),
                           Parent ! {module, self(), M}
                   end),
    M = receive {module, Pid, Mod} -> Mod after 60000 -> ct:fail(timeout) end,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    M.

binary_memory() ->
    erlang:garbage_collect(),
    erlang:memory(binary).

binaries(B) when is_binary(B) -> [B];
binaries(T) when is_tuple(T) -> binaries(tuple_to_list(T));
binaries(L) when is_list(L) -> lists:flatmap(fun binaries/1, L);
binaries(M) when is_map(M) -> binaries(maps:to_list(M));
binaries(_) -> [].

id(X) -> X.

%% A module with a long import name, a long export name, an active and a
%% passive data segment, and custom sections around a `.debug_info' of the
%% given size.
build(DebugBytes) ->
    Long = binary:copy(<<"n">>, 100),
    Seg = binary:copy(<<"d">>, 200),
    Type = section(1, vec([<<16#60, 0, 0>>])),
    Import = section(2, vec([[str(<<"env">>), str(Long), 0, 0]])),
    Func = section(3, vec([<<0>>])),
    Mem = section(5, vec([<<0, 1>>])),
    Export = section(7, vec([[str(Long), 0, 1]])),
    Code = section(10, vec([sized(<<0, 16#0B>>)])),
    Data = section(11, vec([[0, 16#41, 0, 16#0B, sized(Seg)],
                            [1, sized(Seg)]])),
    iolist_to_binary(
      [<<"\0asm", 1:32/little>>,
       custom(<<"name">>, <<0, 1, 0>>),
       Type, Import, Func, Mem, Export,
       custom(<<".debug_info">>, binary:copy(<<"x">>, DebugBytes)),
       Code, Data,
       custom(<<"producers">>, <<0>>),
       custom(<<"tool-data">>, binary:copy(<<"t">>, 100))]).

section(Id, Body) -> [Id, sized(Body)].
custom(Name, Payload) -> section(0, [str(Name), Payload]).
str(B) -> sized(B).
vec(Items) -> [wasm_leb128:encode_u32(length(Items)), Items].

sized(IoData) ->
    Bin = iolist_to_binary(IoData),
    [wasm_leb128:encode_u32(byte_size(Bin)), Bin].
