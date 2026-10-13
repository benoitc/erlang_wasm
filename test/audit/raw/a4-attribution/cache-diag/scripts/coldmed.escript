#!/usr/bin/env escript
%% coldmed.escript RESULTS ARM...: entry_ms per rep and its median, per guest and arm.
main([Dir | Arms]) ->
    [begin
         Fs = lists:sort(filelib:wildcard(filename:join(Dir, "cold/" ++ G ++ "_" ++ A ++ "_r*.terms"))),
         Ms = [begin {ok, [M]} = file:consult(F), M end || F <- Fs],
         Es = [maps:get(entry_ms, M, void) || M <- Ms],
         Vs = [maps:get(verdict, M) || M <- Ms],
         Cs = [maps:get(compiled, maps:get(counts, M)) || M <- Ms],
         io:format("~s ~s ~w median ~w ~w compiled ~w~n", [G, A, Es, lists:nth(2, lists:sort(Es)), Vs, Cs])
     end || G <- ["py_entry", "qjs", "lua", "py"], A <- Arms].
