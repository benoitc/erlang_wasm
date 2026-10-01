-module(retainbench).
-moduledoc """
What a compiled module holds of its input once the input is gone, and what
decode and validate cost.

Use it before changing how `wasm_decode` takes bytes out of the input. A child
reads the file and runs `wasm:compile/1`, then dies; a holder keeps only the
module. The binary memory given back when the holder exits is what the module
held. `max_ref` is the largest `binary:referenced_byte_size/1` over every
binary in the module: the input's size means something still points into it.

    erlc -o bench/paths -I include -pa _build/default/lib/wasm/ebin \\
        bench/paths/retainbench.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run retainbench main test/fixtures/lang/py_reactor.wasm

One file per VM, so nothing an earlier run left counts against a later one.
""".
-export([main/1]).

main([File]) ->
    Self = self(),
    Holder = spawn(fun() -> hold(Self, File) end),
    receive {timing, Us, Size} -> ok end,
    receive {ready, MaxRef} -> ok end,
    B1 = settle(),
    Ref = monitor(process, Holder),
    Holder ! stop,
    receive {'DOWN', Ref, process, Holder, _} -> ok end,
    B2 = settle(),
    io:format("~s size=~p compile_us=~p held_binary=~p max_ref=~p~n",
              [filename:basename(File), Size, Us, B1 - B2, MaxRef]),
    halt().

hold(Parent, File) ->
    {P, R} = spawn_monitor(fun() -> compile(Parent, File) end),
    M = receive {'DOWN', R, process, P, {module, Mod}} -> Mod end,
    erlang:garbage_collect(),
    Parent ! {ready, lists:max([0 | [binary:referenced_byte_size(B)
                                     || B <- binaries(M)]])},
    receive stop -> _ = id(M), ok end.

compile(Parent, File) ->
    {ok, Bin} = file:read_file(File),
    T0 = erlang:monotonic_time(microsecond),
    {ok, M} = wasm:compile(Bin),
    T1 = erlang:monotonic_time(microsecond),
    Parent ! {timing, T1 - T0, byte_size(Bin)},
    exit({module, M}).

settle() ->
    timer:sleep(300),
    _ = [erlang:garbage_collect(P) || P <- processes()],
    timer:sleep(100),
    erlang:memory(binary).

binaries(B) when is_binary(B) -> [B];
binaries(T) when is_tuple(T) -> binaries(tuple_to_list(T));
binaries(L) when is_list(L) -> lists:flatmap(fun binaries/1, L);
binaries(M) when is_map(M) -> binaries(maps:to_list(M));
binaries(_) -> [].

id(X) -> X.
