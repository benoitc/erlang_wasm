#!/usr/bin/env escript
%% coldsum.escript RESULTS ARM...: per guest and arm, the cold terms' scalar
%% fields over the reps.
main([Dir | Arms]) ->
    [begin
         Fs = lists:sort(filelib:wildcard(filename:join(Dir, "cold/" ++ G ++ "_" ++ A ++ "_r*.terms"))),
         Ms = [begin {ok, [M]} = file:consult(F), maps:without([samples, meta], M) end || F <- Fs],
         io:format("~s ~s ~p~n", [G, A, Ms])
     end || G <- ["py_entry", "qjs", "lua", "py"], A <- Arms].
