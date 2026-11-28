-module(ukm1).
-export([main/1]).

%% One boot of the M1 spike. Argument: the arm's name, then the directories
%% to put first on the code path, colon-separated ("-" for none). Prints one
%% RESULT line with every number, so runs can be compared and pasted.
main([Arm, Dirs]) ->
    [true = code:add_patha(D) || D <- string:tokens(Dirs, ":"), D =/= "-", D =/= "none"],
    Load0 = load(),
    Self = self(),
    T0 = now_ms(),
    Log = spawn_link(fun() -> watch(Self, T0, <<>>, []) end),
    {ok, Vm} = unkernel_beam:boot(#{output => Log}),
    Tboot = now_ms() - T0,
    Ti = receive {init, A} -> A after 900000 -> error(no_init) end,
    msacc:start(),
    Tp = receive {prompt, B} -> B after 1800000 -> error(no_prompt) end,
    Msacc = msacc_shares(msacc:stats()),
    msacc:stop(),
    {links, L} = process_info(Vm, links),
    Heaps = lists:sum([W || P <- L, is_pid(P), P =/= Vm,
                            {total_heap_size, W} <- [process_info(P, total_heap_size)]]),
    Execs = [element(1, timer:tc(fun() -> {ok, #{exit_code := 0}} =
                                          unkernel_beam:exec(Vm, "true", [], #{timeout => 900000}) end)) div 1000
             || _ <- [1, 2, 3]],
    #{memory := PtMem} = persistent_term:info(),
    io:format("RESULT arm=~s boot_ms=~b init_ms=~b prompt_ms=~b exec_ms=~w task_heaps_mib=~b "
              "node_mib=~b pt_mib=~b emu=~.1f gc=~.1f load=~s/~s instance=~s uk_vm=~s~n",
              [Arm, Tboot, Ti, Tp, Execs, Heaps * 8 div 1048576,
               erlang:memory(total) div 1048576, PtMem div 1048576,
               maps:get(emulator, Msacc), maps:get(gc, Msacc), Load0, load(),
               short(code:which(wasm_instance)), short(code:which(uk_vm))]),
    unkernel_beam:stop(Vm),
    halt(0).

%% Of all scheduler and dirty-CPU time between /init and the prompt, the
%% share spent running Erlang code and the share spent collecting.
msacc_shares(Stats) ->
    Ts = [maps:get(counters, S) || #{type := T} = S <- Stats,
                                   T =:= scheduler orelse T =:= dirty_cpu_scheduler],
    Sum = fun(K) -> lists:sum([maps:get(K, C, 0) || C <- Ts]) end,
    Busy = lists:sum([Sum(K) || K <- [emulator, gc, other, port, aux, check_io]]),
    #{emulator => 100 * Sum(emulator) / max(1, Busy), gc => 100 * Sum(gc) / max(1, Busy)}.

short(Path) -> filename:basename(filename:dirname(filename:dirname(Path))) ++ "/" ++
                   filename:basename(filename:dirname(Path)).

load() -> lists:nth(2, string:tokens(os:cmd("sysctl -n vm.loadavg"), " {}")).

watch(Main, T0, Buf, Seen) ->
    receive
        {unkernel_output, _, Bytes} ->
            All = <<Buf/binary, Bytes/binary>>,
            S1 = mark(Main, T0, All, <<"Run /init">>, init, Seen),
            S2 = mark(Main, T0, All, <<"~ # ">>, prompt, S1),
            watch(Main, T0, binary:part(All, max(0, byte_size(All) - 64), min(64, byte_size(All))), S2)
    end.

mark(Main, T0, All, Needle, Tag, Seen) ->
    case lists:member(Tag, Seen) orelse binary:match(All, Needle) =:= nomatch of
        true -> Seen;
        false -> Main ! {Tag, now_ms() - T0}, [Tag | Seen]
    end.

now_ms() -> erlang:monotonic_time(millisecond).
