#!/usr/bin/env escript
%% Per raw file: keeper calls per instance (median) by function, rows
%% charged per key, and the unowned rows at the end.
main(Files) ->
    [begin
         {ok, B} = file:read_file(F),
         B1 = re:replace(B, "#Ref<[0-9.]+>", "ref", [global]),
         B2 = re:replace(B1, "<([0-9]+\\.[0-9]+\\.[0-9]+)>", "{pid,\"\\1\"}",
                         [global]),
         {ok, Ts, _} = erl_scan:string(binary_to_list(iolist_to_binary(B2))),
         {ok, R} = erl_parse:parse_term(Ts),
         #{instances := Is, log := Log, count := N, pages_end := PE} = R,
         Pids = [maps:get(pid, I) || I <- Is],
         Per = fun(Fn) -> med([length([1 || #{pid := P, f := X} <- Log,
                                            P =:= Pid, X =:= Fn])
                               || Pid <- Pids]) end,
         Keys = lists:usort([maps:get(phys, Row) || I <- Is,
                             #{kind := memory} = Row <- maps:get(rows_after, I)]),
         io:format("~s count=~p pages_end=~p count*per=~p reserve=~p "
                   "arena_begin=~p grow_begin=~p phys=~p unowned=~p~n",
                   [filename:basename(F), N, PE,
                    N * (maps:get(pages_after, hd(Is)) - maps:get(pages_before, hd(Is))),
                    Per(reserve), Per(arena_begin), Per(grow_begin), Keys,
                    [maps:get(charged, U) || U <- maps:get(rows_end_unowned, R)]])
     end || F <- Files].
med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).
