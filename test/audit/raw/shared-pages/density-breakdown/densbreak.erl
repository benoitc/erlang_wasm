-module(densbreak).
-moduledoc """
Where each instance's budget pages go, at `page_limit` 4096.

The `density` fill of `densitybench`, one instance at a time, each held in its
own process. For every instance the keeper rows the holder owns are read
(`wasm_holders`, `{Res, Meta, Pages, Holders, Ledger}`) right after
`wasm:restore/3` returns and again after the request, with the memory's
first-write state: on mmap `wasm_mem_nif:charges/1` (credit chunks, unused
credit, host pages written), on paged the arena slots claimed, chunks
published and 4 KiB pages made private. `wasm_keeper:reserve/4`,
`grow_begin/4` and `arena_begin/4` are traced with their answers, so every
purchase is attributed to its instance and the refusal to its ledger key.

    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/arb -pa DIR \
        -run densbreak main py OUT.terms

Reads only; nothing in `src/` is changed.
""".
-export([main/1]).

-define(CACHE, "_build/imagecache").
-define(PT, {?MODULE, image}).
-define(LIMITS, #{fuel => infinity, timeout => infinity,
                  max_memory_pages => 65536}).
-define(CAP, 5000).

main([Guest, Raw]) ->
    try
        R = run(list_to_atom(Guest)),
        ok = file:write_file(Raw, io_lib:format("~p.~n", [R])),
        summary(R)
    catch C:E:S -> io:format("failed: ~p~n~p~n", [{C, E}, S])
    end,
    erlang:halt(0).

run(Name) ->
    ok = reactorlib:page_limit(4096),
    Meta = reactorlib:meta(),
    {ok, G} = reactorlib:guest(Name),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    persistent_term:put(?PT, Image),
    Backend = case maps:is_key(nif, wasm_memory:field_indices()) of
                  true -> mmap;
                  false -> paged
              end,
    HostPage = case Backend of
                   mmap -> wasm_mem_nif:host_page();
                   paged -> 4096
               end,
    P0 = wasm_engine:pages_in_use(),
    Rows0 = rows(),
    T = start_tracer(),
    {Insts, Failure, Hs} = fill(G, 0, [], []),
    _ = trace_sync(T),
    Log = trace_log(T),
    stop_trace(),
    PEnd = wasm_engine:pages_in_use(),
    RowsEnd = rows(),
    teardown(Hs),
    #{guest => Name, backend => Backend, host_page => HostPage, meta => Meta,
      os => os:type(), arch => erlang:system_info(system_architecture),
      page_limit => wasm_engine:page_limit(),
      pages_before => P0, pages_end => PEnd, count => length(Insts),
      rows_before => Rows0, rows_end_unowned => unowned(RowsEnd, Hs),
      instances => lists:reverse(Insts), failure => Failure, log => Log}.

fill(_G, N, Acc, Hs) when N >= ?CAP -> {Acc, cap, Hs};
fill(G, N, Acc, Hs) ->
    Self = self(),
    PBefore = wasm_engine:pages_in_use(),
    {P, M} = spawn_monitor(fun() -> holder(Self, G) end),
    receive
        {restored, P, MemR} ->
            RowsR = owned(P),
            PR = wasm_engine:pages_in_use(),
            P ! go,
            receive
                {held, P, ok, MemQ} ->
                    I = #{n => N + 1, pid => P, pages_before => PBefore,
                          pages_restored => PR,
                          pages_after => wasm_engine:pages_in_use(),
                          rows_restored => RowsR, rows_after => owned(P),
                          mem_restored => MemR, mem_after => MemQ},
                    fill(G, N + 1, [I | Acc], [{P, M} | Hs]);
                {held, P, Fail, MemQ} ->
                    receive {'DOWN', M, process, P, _} -> ok end,
                    {Acc, #{n => N + 1, pid => P, stage => request,
                            failure => Fail, rows_restored => RowsR,
                            pages_before => PBefore, pages_restored => PR,
                            mem_restored => MemR, mem_at_failure => MemQ},
                     Hs}
            end;
        {held, P, Fail, MemQ} ->
            receive {'DOWN', M, process, P, _} -> ok end,
            {Acc, #{n => N + 1, pid => P, stage => restore, failure => Fail,
                    pages_before => PBefore, mem_at_failure => MemQ}, Hs};
        {'DOWN', M, process, P, Why} ->
            {Acc, #{n => N + 1, stage => died, why => Why}, Hs}
    end.

holder(Parent, G) ->
    Image = persistent_term:get(?PT),
    case request(G, Image, Parent) of
        {ok, R, Inst} ->
            Info = mem_info(Inst),
            Parent ! {held, self(),
                      case R =:= reactorlib:expected(G) of
                          true -> ok;
                          false -> {wrong, R}
                      end, Info},
            receive stop -> ok = wasm:destroy(Inst) end;
        {error, Stage, E, Info} ->
            Parent ! {held, self(), {failed, Stage, summary_err(E)}, Info}
    end.

summary_err(#{class := C, kind := K} = E) ->
    {C, K, maps:get(ctx, E, #{})};
summary_err(E) -> E.

%%% ------------------------------------------------------------- request ---

%% `reactorlib:request/2', with a stop after the restore so the parent can
%% read the rows, and the instance's memory state kept on failure.
request(G, Image, Parent) ->
    #{adapter := A, artifact := Art, cap := Cap, request := Req} = G,
    {ok, _} = A:requirements(Req, Art),
    Dir = private_dir(),
    Chans = #{stdout => channel(stdout), stderr => channel(stderr),
              result => channel(result)},
    Env = #{mounts => #{ro => #{guest_path => ~"/", host_dir => Dir,
                                mode => read}},
            channels => Chans, deadline => infinity, limits => ?LIMITS,
            cleanup => #{register => fun(_) -> {ok, make_ref()} end,
                         withdraw => fun(_) -> ok end},
            stage => fun(ro, Path, Data) ->
                             file:write_file(filename:join(Dir, Path), Data)
                     end},
    {ok, #{imports := IS, invoke := Invoke}, AState} = A:prepare(Req, Art, Env),
    Opts = maps:merge(?LIMITS, restore_opts(IS)),
    R = case wasm:restore(Image, maps:get(bindings, IS), Opts) of
            {error, E} ->
                {error, restore, E, none};
            {ok, Inst} ->
                Parent ! {restored, self(), mem_info(Inst)},
                receive go -> ok end,
                served(A, Cap, Image, Inst, Invoke, AState, Chans)
        end,
    _ = file:del_dir_r(Dir),
    [ets:delete(T) || {channel, _, T, _, _} <- maps:values(Chans)],
    R.

served(A, #{post_restore := F}, Image, Inst, Invoke, AState, Chans) ->
    #{module := M, version := V} = wasm:snapshot_info(Image),
    case F(Inst, #{module => M, version => V}) of
        ok ->
            Exec = invoke(Invoke, Inst, A, AState),
            Out = A:decode(executed(Exec, Chans), AState),
            case Out of
                {ok, #{result := Result}} -> {ok, Result, Inst};
                Other ->
                    Info = mem_info(Inst),
                    ok = wasm:destroy(Inst),
                    {error, decode, Other, Info}
            end;
        Refused ->
            Info = mem_info(Inst),
            ok = wasm:destroy(Inst),
            {error, post_restore, Refused, Info}
    end.

invoke([{call, Name, Args} | Rest], Inst, A, AState) ->
    IR = wasm:call(Inst, Name, Args, ?LIMITS),
    case {A:classify(IR, AState), Rest, IR} of
        {continue, [], {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {continue, [], {error, E}} -> {trapped, [], undefined, E};
        {continue, _, _} -> invoke(Rest, Inst, A, AState);
        {{stop, returned}, _, {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {{stop, {exited, C}}, _, {ok, Vs}} -> {exited, Vs, C, undefined};
        {{stop, {exited, C}}, _, {error, E}} -> {exited, [], C, E};
        {_, _, {ok, Vs}} -> {trapped, Vs, undefined, undefined};
        {_, _, {error, E}} -> {trapped, [], undefined, E}
    end.

executed({Outcome, Values, Exit, Err}, Chans) ->
    Read = fun(K) -> read_channel(maps:get(K, Chans)) end,
    {Out, TO} = Read(stdout),
    {Er, TE} = Read(stderr),
    {Res, TR} = Read(result),
    #{outcome => Outcome, values => Values, exit => Exit, error => Err,
      channels => #{stdout => Out, stderr => Er, result => Res},
      truncated => #{stdout => TO, stderr => TE, result => TR}}.

channel(Which) ->
    {channel, Which, ets:new(densbreak_channel, [ordered_set, public]),
     atomics:new(1, []), 1_048_576}.

read_channel({channel, _, Tab, Counter, Limit}) ->
    {iolist_to_binary([D || {_, D} <- ets:tab2list(Tab)]),
     atomics:get(Counter, 1) > Limit}.

restore_opts(IS) ->
    Base = case maps:get(snapshot_hooks, IS, #{}) of
               Empty when map_size(Empty) =:= 0 -> #{};
               Hooks -> #{snapshot_hooks => Hooks}
           end,
    case maps:get(compatibility_key, IS, undefined) of
        undefined -> Base;
        Key -> Base#{compatibility_key => Key}
    end.

private_dir() ->
    Dir = filename:join([filename:basedir(user_cache, "erlang_wasm_bench"),
                         "dens-" ++ os:getpid() ++ "-" ++ integer_to_list(
                                      erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

%%% -------------------------------------------------------- introspection ---

%% Memory 0's size and first-write state.
mem_info(Inst) ->
    case wasm:extern(Inst, ~"memory") of
        {ok, Mem} when is_tuple(Mem), element(1, Mem) =:= mem ->
            mem_state(Mem);
        Other -> {no_memory, Other}
    end.

mem_state(Mem) ->
    Ix = wasm_memory:field_indices(),
    Pages = wasm_memory:size_pages(Mem),
    case maps:find(nif, Ix) of
        {ok, NI} ->
            Nif = element(NI, Mem),
            {Chunks, Credit, Written} = wasm_mem_nif:charges(Nif),
            #{pages => Pages, img_pages => img_pages(mmap, Mem, Ix),
              credit_chunks => Chunks, unused_credit_host_pages => Credit,
              written_host_pages => Written};
        error ->
            IB = element(maps:get(img_bytes, Ix), Mem),
            case IB of
                0 -> #{pages => Pages, img_pages => 0};
                _ ->
                    Tab = element(maps:get(tab, Ix), Mem),
                    Next = (IB bsr 12) + 1,
                    Private = length([P || P <- lists:seq(1, Next - 1),
                                           atomics:get(Tab, P) =/= 0]),
                    #{pages => Pages, img_pages => IB div 65536,
                      slots_claimed => atomics:get(Tab, Next),
                      arena_chunks => atomics:get(Tab, Next + 1),
                      private_4k_pages => Private}
            end
    end.

img_pages(mmap, _Mem, _Ix) -> unknown.

%% Every ledger row; the counter and cap rows are left out.
rows() ->
    [row_view(R) || R <- ets:tab2list(wasm_holders), is_ledger(R)].

is_ledger({_, _, _, H, L}) when is_map(H), is_map(L) -> true;
is_ledger(_) -> false.

owned(Pid) ->
    [row_view(R) || {_, _, _, H, _} = R <- ets:tab2list(wasm_holders),
                    is_ledger(R),
                    lists:member(Pid, maps:values(H))].

unowned(_Rows, Hs) ->
    Pids = [P || {P, _} <- Hs],
    [row_view(R) || {_, _, _, H, _} = R <- ets:tab2list(wasm_holders),
                    is_ledger(R),
                    not lists:any(fun(O) -> lists:member(O, Pids) end,
                                  maps:values(H))].

row_view({Res, Meta, L, H, Ledger}) ->
    #{res => Res, kind => kind(Meta), meta => meta_view(Meta), size => L,
      holders => maps:size(H), phys => maps:get(phys, Ledger, none),
      charged => charged(Meta, L, Ledger)}.

kind(T) when is_tuple(T) -> element(1, T);
kind(A) -> A.

meta_view({memory, _, _, _, _, Geo}) -> {memory, Geo};
meta_view({image, B}) -> {image, B};
meta_view(M) -> M.

charged({memory, _, _, _, _, _}, _L, #{phys := Phys}) ->
    maps:fold(fun(_, V, A) -> A + V end, 0, Phys);
charged({image, _}, _L, _) -> 0;
charged(_, L, _) -> L.

%%% --------------------------------------------------------------- trace ---

start_tracer() ->
    T = spawn_link(fun() -> tracer(#{}, []) end),
    [1 = erlang:trace_pattern({wasm_keeper, F, A},
                              [{'_', [], [{return_trace}]}], [global])
     || {F, A} <- [{reserve, 4}, {grow_begin, 4}, {arena_begin, 4}]],
    _ = erlang:trace(all, true, [call, {tracer, T}]),
    T.

stop_trace() ->
    _ = erlang:trace(all, false, [call]),
    [erlang:trace_pattern({wasm_keeper, F, A}, false, [global])
     || {F, A} <- [{reserve, 4}, {grow_begin, 4}, {arena_begin, 4}]],
    ok.

tracer(Pending, Log) ->
    receive
        {trace, Pid, call, {wasm_keeper, F, Args}} ->
            tracer(Pending#{Pid => {F, args(F, Args)}}, Log);
        {trace, Pid, return_from, {wasm_keeper, F, _}, R} ->
            {F, A} = maps:get(Pid, Pending, {F, unknown}),
            E = #{pid => Pid, f => F, args => A, result => result(R),
                  pages_in_use => wasm_engine:pages_in_use()},
            tracer(maps:remove(Pid, Pending), [E | Log]);
        {log, From} ->
            From ! {log, self(), lists:reverse(Log)},
            tracer(Pending, Log);
        _ ->
            tracer(Pending, Log)
    end.

args(reserve, [Pages, Meta, _Token, _Owner]) ->
    #{pages => Pages, meta => meta_view(Meta)};
args(grow_begin, [_Res, _Op, Delta, _Ceil]) -> #{delta => Delta};
args(arena_begin, [_Res, _Op, Target, {Have, Pages}]) ->
    #{have => Have, target => Target, budget_pages => Pages};
args(_, _) -> unknown.

result({ok, R}) when is_reference(R) -> ok;
result(R) -> R.

trace_sync(_T) ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end.

trace_log(T) ->
    T ! {log, self()},
    receive {log, T, L} -> L end.

teardown(Hs) ->
    [P ! stop || {P, _} <- Hs],
    [receive {'DOWN', M, process, P, _} -> ok after 60000 -> exit(P, kill) end
     || {P, M} <- Hs],
    ok.

%%% ------------------------------------------------------------- summary ---

summary(#{guest := G, backend := B, count := N, instances := Is,
          failure := F, log := Log, host_page := HP} = R) ->
    io:format("guest=~p backend=~p host_page=~p count=~p pages_before=~p "
              "pages_end=~p arch=~s~n",
              [G, B, HP, N, maps:get(pages_before, R), maps:get(pages_end, R),
               maps:get(arch, R)]),
    case Is of
        [] -> ok;
        _ ->
            Mid = lists:nth((length(Is) + 1) div 2, Is),
            io:format("median-n instance ~p:~n  restored rows ~p~n"
                      "  after rows ~p~n  mem_restored ~p~n  mem_after ~p~n",
                      [maps:get(n, Mid), strip(maps:get(rows_restored, Mid)),
                       strip(maps:get(rows_after, Mid)),
                       maps:get(mem_restored, Mid),
                       maps:get(mem_after, Mid)]),
            D = [maps:get(pages_after, I) - maps:get(pages_before, I)
                 || I <- Is],
            io:format("per-instance delta: min ~p max ~p mean ~.2f~n",
                      [lists:min(D), lists:max(D), lists:sum(D) / length(D)])
    end,
    io:format("failure: ~p~n", [maps:without([rows_restored], F)]),
    FPid = maps:get(pid, F, none),
    io:format("failing instance's calls: ~p~n",
              [[maps:without([pid], E) || #{pid := P} = E <- Log,
                                          P =:= FPid]]),
    Refused = [E || #{result := {error, _}} = E <- Log],
    io:format("refusals in whole run: ~p~n", [length(Refused)]).

strip(Rows) -> [maps:without([res, meta], R) || R <- Rows].
