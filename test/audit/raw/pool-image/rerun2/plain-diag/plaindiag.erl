-module(plaindiag).
-export([main/1]).
%% Where plain's load_snapshot time goes, per phase: reading the file, decoding
%% it, from_parts, and the whole call. N samples each, medians in microseconds.
main([NS, Out]) ->
    N = list_to_integer(NS),
    ok = reactorlib:page_limit(65536),
    {ok, G} = reactorlib:guest(plain),
    Path = reactorlib:image_path(G, "_build/imagecache"),
    H = maps:get(module, G),
    {ok, M} = wasm_module_cache:get(H),
    {ok, Bin} = file:read_file(Path),
    {ok, Lim} = wasm_snapshot_file:limits(),
    {ok, Parts} = wasm_snapshot_file:decode(Bin, Lim),
    Read = [t(fun() -> {ok, _} = file:read_file(Path) end) || _ <- lists:seq(1, N)],
    Dec = [t(fun() -> {ok, _} = wasm_snapshot_file:decode(Bin, Lim) end) || _ <- lists:seq(1, N)],
    FP = [t(fun() -> {ok, _} = wasm_snapshot:from_parts(Parts, H, M) end) || _ <- lists:seq(1, N)],
    Full = [begin T0 = erlang:monotonic_time(nanosecond),
                  {ok, S} = wasm:load_snapshot(Path, H),
                  T1 = erlang:monotonic_time(nanosecond),
                  ok = wasm:release(S), (T1 - T0) / 1000 end || _ <- lists:seq(1, N)],
    R = #{uptime => os:cmd("uptime"), read => med(Read), decode => med(Dec),
          from_parts => med(FP), load => med(Full)},
    ok = file:write_file(Out, io_lib:format("~p.~n", [R])),
    io:format("~p~n", [R]),
    halt().
med(L) -> S = lists:sort(L), lists:nth((length(S) + 1) div 2, S).
t(F) -> T0 = erlang:monotonic_time(nanosecond), F(),
        (erlang:monotonic_time(nanosecond) - T0) / 1000.
