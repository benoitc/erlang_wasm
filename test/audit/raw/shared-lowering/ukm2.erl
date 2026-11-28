-module(ukm2).
-export([main/0]).

%% M2 of the shared-lowering plan: at the unkernel shell prompt, what each
%% kernel task lowered and keeps. Per task: the bodies in its dictionary, their
%% size, its heap. Per body: how many tasks hold it. The largest bodies, by
%% name. And every wasm_instance:lower/2 call during the boot.
%%
%% The dictionary is copied out of each task by process_info/2, which does
%% not keep sharing inside a term, so sizes are flat sizes: an upper bound on
%% what the task's heap holds for them.
main() ->
    Names = guest_names(),
    {module, _} = code:ensure_loaded(wasm_instance),
    {ok, _} = application:ensure_all_started(wasm),
    1 = erlang:trace_pattern({wasm_instance, lower, 2}, true, [call_count]),
    Self = self(),
    T0 = erlang:monotonic_time(millisecond),
    Log = spawn_link(fun() -> watch(Self, <<>>) end),
    {ok, Vm} = unkernel_beam:boot(#{output => Log}),
    receive prompt -> ok after 1800000 -> error(no_prompt) end,
    Tp = erlang:monotonic_time(millisecond) - T0,
    {call_count, Lowered} = erlang:trace_info({wasm_instance, lower, 2}, call_count),
    1 = erlang:trace_pattern({wasm_instance, lower, 2}, false, [call_count]),
    {links, L} = process_info(Vm, links),
    Tasks = [{P, Bodies, Heap}
             || P <- L, is_pid(P),
                {dictionary, D} <- [process_info(P, dictionary)],
                Bodies <- [[{Idx, erts_debug:flat_size(IR)} || {{wasm_ir, _, Idx}, IR} <- D]],
                Bodies =/= [],
                {total_heap_size, Heap} <- [process_info(P, total_heap_size)]],
    Held = lists:foldl(fun({_, Bs, _}, Acc) ->
                               lists:foldl(fun({I, W}, A) ->
                                                   maps:update_with(I, fun({N, _}) -> {N + 1, W} end,
                                                                    {1, W}, A)
                                           end, Acc, Bs)
                       end, #{}, Tasks),
    TaskWords = [lists:sum([W || {_, W} <- Bs]) || {_, Bs, _} <- Tasks],
    Distinct = lists:sum([W || {_, {_, W}} <- maps:to_list(Held)]),
    io:format("prompt at ~.1f s; ~b tasks hold lowered bodies; lower/2 calls during the boot: ~b~n",
              [Tp / 1000, length(Tasks), Lowered]),
    io:format("distinct bodies held: ~b, ~.1f MiB flat once each; held by all tasks: ~.1f MiB flat~n",
              [map_size(Held), Distinct * 8 / 1048576, lists:sum(TaskWords) * 8 / 1048576]),
    io:format("~nper task (bodies, flat MiB of them, heap MiB):~n"),
    [io:format("  ~p ~6b bodies ~7.2f MiB  heap ~7.1f MiB~n",
               [P, length(Bs), lists:sum([W || {_, W} <- Bs]) * 8 / 1048576, H * 8 / 1048576])
     || {P, Bs, H} <- lists:reverse(lists:keysort(3, Tasks))],
    Hist = lists:foldl(fun({_, {N, _}}, A) -> maps:update_with(N, fun(X) -> X + 1 end, 1, A) end,
                       #{}, maps:to_list(Held)),
    io:format("~nbodies by how many tasks hold them (holders: bodies):~n  ~p~n",
              [lists:sort(maps:to_list(Hist))]),
    io:format("~nthe 20 largest bodies (index, flat words, holders, name):~n"),
    [io:format("  ~6b ~9b ~3b  ~s~n", [I, W, N, maps:get(I, Names, <<"?">>)])
     || {W, I, N} <- lists:sublist(lists:reverse(lists:sort([{W, I, N} || {I, {N, W}} <- maps:to_list(Held)])), 20)],
    case maps:find(18152, Held) of
        {ok, {KN, KW}} -> io:format("~nkw_run (18152): ~b flat words, held by ~b tasks~n", [KW, KN]);
        error -> io:format("~nkw_run (18152): held by no task~n")
    end,
    halt(0).

watch(Main, Buf) ->
    receive {unkernel_output, _, B} ->
        All = <<Buf/binary, B/binary>>,
        case binary:match(All, <<"~ # ">>) of
            nomatch -> watch(Main, binary:part(All, max(0, byte_size(All) - 32), min(32, byte_size(All))));
            _ -> Main ! prompt, sink()
        end
    end.
sink() -> receive _ -> sink() end.

guest_names() ->
    {ok, B} = file:read_file(filename:join(code:priv_dir(unkernel_beam), "unkernel.wasm")),
    {ok, M} = wasm_decode:module(B),
    [Sec] = [V || L <- tuple_to_list(M), is_list(L), L =/= [], is_tuple(hd(L)),
                  tuple_size(hd(L)) =:= 2, is_binary(element(1, hd(L))),
                  {<<"name">>, V} <- L],
    subsections(Sec, #{}).
subsections(<<>>, Acc) -> Acc;
subsections(<<Id, Rest0/binary>>, Acc) ->
    {Len, Rest1} = wasm_leb128:u32(Rest0),
    <<Body:Len/binary, Rest/binary>> = Rest1,
    case Id of 1 -> subsections(Rest, func_names(Body)); _ -> subsections(Rest, Acc) end.
func_names(Body) -> {N, R} = wasm_leb128:u32(Body), func_names(N, R, #{}).
func_names(0, _, Acc) -> Acc;
func_names(N, R0, Acc) ->
    {Idx, R1} = wasm_leb128:u32(R0), {L, R2} = wasm_leb128:u32(R1),
    <<Name:L/binary, R3/binary>> = R2,
    func_names(N - 1, R3, Acc#{Idx => Name}).
