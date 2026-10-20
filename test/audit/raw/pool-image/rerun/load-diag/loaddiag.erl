-module(loaddiag).
-export([main/1]).
%% Where load_snapshot's time goes: decode, from_parts, the whole call.
main([Gs, NS, Out]) ->
    N = list_to_integer(NS),
    ok = reactorlib:page_limit(65536),
    R = [one(list_to_atom(G), N) || G <- string:lexemes(Gs, ",")],
    ok = file:write_file(Out, io_lib:format("~p.~n", [#{uptime => os:cmd("uptime"), results => R}])),
    io:format("~p~n", [R]),
    halt().
med(L) -> S = lists:sort(L), lists:nth((length(S)+1) div 2, S).
t(F) -> true = erlang:garbage_collect(), T0 = erlang:monotonic_time(nanosecond), R = F(), {(erlang:monotonic_time(nanosecond) - T0)/1000, R}.
one(Name, N) ->
    {ok, G} = reactorlib:guest(Name),
    Path = reactorlib:image_path(G, "_build/imagecache"),
    H = maps:get(module, G),
    {ok, M} = wasm_module_cache:get(H),
    {ok, Bin} = file:read_file(Path),
    {ok, Lim} = wasm_snapshot_file:limits(),
    {ok, Parts} = wasm_snapshot_file:decode(Bin, Lim),
    Dec = [element(1, t(fun() -> {ok, _} = wasm_snapshot_file:decode(Bin, Lim) end)) || _ <- lists:seq(1, N)],
    FP = [element(1, t(fun() -> {ok, _} = wasm_snapshot:from_parts(Parts, H, M) end)) || _ <- lists:seq(1, N)],
    Full = [begin {T, {ok, S}} = t(fun() -> wasm:load_snapshot(Path, H) end), ok = wasm:release(S), T end || _ <- lists:seq(1, N)],
    Tabs = [length(T) || T <- maps:get(tables, Parts)],
    Fresh = [fresh(Path, H) || _ <- lists:seq(1, N)],
    {Name, #{decode_p50 => med(Dec), from_parts_p50 => med(FP), load_p50 => med(Full), fresh_process_load_p50 => med(Fresh), tables => Tabs}}.

%% The same call in a new process each time, so no caller's heap differs.
fresh(Path, H) ->
    Self = self(),
    spawn(fun() -> T0 = erlang:monotonic_time(nanosecond), {ok, S} = wasm:load_snapshot(Path, H), T1 = erlang:monotonic_time(nanosecond), ok = wasm:release(S), Self ! {t, self(), (T1 - T0) / 1000} end),
    receive {t, _, T} -> T end.
