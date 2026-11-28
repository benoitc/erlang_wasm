-module(ukg).
-export([main/1]).

%% One unkernel boot for the shared-lowering gates. Arguments: a label, the
%% erlang_wasm build to run on, and the directory holding the uk_vm variant.
%% Prints one RESULT line: boot to prompt, the processes' heaps, the node's
%% and persistent_term's memory, lower/2 calls, generations published, and
%% which code ran.
main([Label, Ew, Variant]) ->
    [true = code:add_patha(filename:join([Ew, "_build/default/lib", L, "ebin"]))
     || L <- ["h2", "h1", "wasm"]],
    true = code:add_patha(Variant),
    {module, _} = code:ensure_loaded(wasm_instance),
    1 = erlang:trace_pattern({wasm_instance, lower, 2}, true, [call_count]),
    Load0 = load(),
    Self = self(),
    T0 = now_ms(),
    Log = spawn_link(fun() -> watch(Self, T0, <<>>, []) end),
    {ok, Vm} = unkernel_beam:boot(#{output => Log}),
    Ti = receive {init, A} -> A after 900000 -> error(no_init) end,
    Tp = receive {prompt, B} -> B after 1800000 -> error(no_prompt) end,
    {call_count, Lowered} = erlang:trace_info({wasm_instance, lower, 2}, call_count),
    {links, L} = process_info(Vm, links),
    Heaps = lists:sum([W || P <- L, is_pid(P), P =/= Vm,
                            {total_heap_size, W} <- [process_info(P, total_heap_size)]]),
    #{memory := PtMem} = persistent_term:info(),
    Gens = length([K || {{wasm_ir_shared, _, _, _} = K, _} <- persistent_term:get()]),
    io:format("RESULT label=~s prompt_ms=~b init_ms=~b task_heaps_mib=~b node_mib=~b "
              "pt_mib=~b lowerings=~b generations=~b load=~s/~s wasm=~s uk_vm=~s~n",
              [Label, Tp, Ti, Heaps * 8 div 1048576, erlang:memory(total) div 1048576,
               PtMem div 1048576, Lowered, Gens, Load0, load(),
               code:which(wasm_instance), code:which(uk_vm)]),
    erlang:halt(0).

load() -> lists:nth(2, string:tokens(os:cmd("sysctl -n vm.loadavg"), " {}")).

watch(Main, T0, Buf, Seen) ->
    receive
        {unkernel_output, _, Bytes} ->
            All = <<Buf/binary, Bytes/binary>>,
            S1 = mark(Main, T0, All, <<"Run /init">>, init, Seen),
            S2 = mark(Main, T0, All, <<"~ # ">>, prompt, S1),
            watch(Main, T0, binary:part(All, max(0, byte_size(All) - 64),
                                        min(64, byte_size(All))), S2)
    end.

mark(Main, T0, All, Needle, Tag, Seen) ->
    case lists:member(Tag, Seen) orelse binary:match(All, Needle) =:= nomatch of
        true -> Seen;
        false -> Main ! {Tag, now_ms() - T0}, [Tag | Seen]
    end.

now_ms() -> erlang:monotonic_time(millisecond).
