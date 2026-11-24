-module(tlbbench).
%% PR C gates: cold compile (trigger to publication), warm _start, the size of
%% the generated module, guest output, on the build it runs on. One run per VM.
%%
%%   erl -noshell -pa STREE/_build/default/lib/*/ebin -pa SP \
%%       -run selbench main time "46,47,48"
%%   ... main cross "46,47,48"
%%   ... main time ""          (the base set)
-export([main/1]).
-include("wasm.hrl").
-include("wasm_validate.hrl").
-include("wasm_exec.hrl").

-define(EXPECTED, <<"864318946\n">>).

main([Mode, Excl0]) -> main([Mode, Excl0, ""]);
main([Mode, Excl0, Tag]) ->
    Excl = [list_to_integer(X) || X <- string:lexemes(Excl0, ",")],
    ok = application:load(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    R = try run(list_to_atom(Mode), Excl)
        catch C:E:S -> #{failed => {C, E, S}}
        end,
    io:format("~p.~n", [R#{excl => Excl, mode => Mode, tag => Tag,
                           load_end => load()}]),
    halt(case R of #{failed := _} -> 1; _ -> 0 end).

load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).

run(time, Excl) ->
    {M, Cfg} = qjs(),
    Opts = #{compile => true, compile_after => 1},
    L0 = load(),
    Self0 = self(),
    {module, compile} = code:ensure_loaded(compile),
    1 = erlang:trace_pattern({compile, forms, 2}, [{'_', [], [{return_trace}]}], [global]),
    Sizer = spawn(fun() -> sizer(Self0) end),
    _ = erlang:trace(all, true, [call, {tracer, Sizer}]),
    %% Cold: the tier asks for the compile at the end of the first `_start';
    %% published is when `await/2' returns on the second instance.
    {ok, Cold} = in_process(fun() ->
        {ok, I} = wasm:instantiate(M, imports(Cfg, self()), Opts),
        {ok, _} = wasm:call(I, ~"_start", []),
        T0 = erlang:monotonic_time(),
        {ok, J} = wasm:instantiate(M, imports(Cfg, self()), Opts),
        ok = wasm_jit:await(J, 900000),
        T1 = erlang:monotonic_time(),
        ok = check_output(),
        ok = wasm:destroy(J), ok = wasm:destroy(I),
        {ok, T1 - T0}
    end),
    _ = erlang:trace(all, false, [call]),
    Bytes = receive {beam_bytes, B} -> B after 5000 -> none end,
    Counts = wasm_jit:counts(),
    ok = check_counts(Counts, Excl),
    Warm = [in_process(fun() ->
                {ok, I} = wasm:instantiate(M, imports(Cfg, self()), Opts),
                T0 = erlang:monotonic_time(),
                {ok, _} = wasm:call(I, ~"_start", []),
                T1 = erlang:monotonic_time(),
                ok = check_output(),
                ok = wasm:destroy(I),
                T1 - T0
            end) || _ <- [1, 2, 3]],
    Us = fun(T) -> erlang:convert_time_unit(T, native, microsecond) end,
    #{cold_us => Us(Cold), warm_us => [Us(T) || T <- Warm], beam_bytes => Bytes,
      load_start => L0, counts => wasm_jit:counts()};

%% Crossings, untimed: every call out of generated code, by target.
run(cross, Excl) ->
    {M, Cfg} = qjs(),
    Opts = #{compile => true, compile_after => 1},
    ok = in_process(fun() ->
        {ok, I} = wasm:instantiate(M, imports(Cfg, self()), Opts),
        {ok, _} = wasm:call(I, ~"_start", []),
        {ok, J} = wasm:instantiate(M, imports(Cfg, self()), Opts),
        ok = wasm_jit:await(J, 900000),
        ok = check_output(),
        ok = wasm:destroy(J), ok = wasm:destroy(I)
    end),
    ok = check_counts(wasm_jit:counts(), Excl),
    Self = self(),
    Tally = spawn(fun() -> tally(Self, #{}) end),
    {module, wasm_exec} = code:ensure_loaded(wasm_exec),
    1 = erlang:trace_pattern({wasm_exec, call_out, 7}, true, [global]),
    1 = erlang:trace_pattern({wasm_exec, indirect_out, 9}, true, [global]),
    Out = in_process(fun() ->
        {ok, I} = wasm:instantiate(M, imports(Cfg, self()), Opts),
        _ = erlang:trace(self(), true, [call, {tracer, Tally}]),
        {ok, _} = wasm:call(I, ~"_start", []),
        _ = erlang:trace(self(), false, [call]),
        ok = check_output(),
        Funcs = I#inst.funcs,
        ok = wasm:destroy(I),
        Funcs
    end),
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    Tally ! done,
    ByIdx = receive {tally, T} -> T end,
    Kind = fun(Idx) when is_integer(Idx) ->
                   case element(Idx + 1, Out) of
                       #hostfn{} -> host;
                       _ -> guest
                   end;
              (_) -> indirect
           end,
    Split = maps:fold(fun(Idx, N, A) ->
                              maps:update_with(Kind(Idx), fun(X) -> X + N end,
                                               N, A)
                      end, #{}, ByIdx),
    Top = lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(ByIdx))), 10),
    #{crossings => Split, top_targets => Top}.

sizer(Owner) ->
    receive
        {trace, _, return_from, {compile, forms, 2}, {ok, _, Bin}} ->
            Owner ! {beam_bytes, byte_size(Bin)};
        _ -> sizer(Owner)
    end.

tally(Owner, Acc) ->
    receive
        {trace, _, call, {wasm_exec, call_out, [_, _, Idx | _]}} ->
            tally(Owner, maps:update_with(Idx, fun(N) -> N + 1 end, 1, Acc));
        {trace, _, call, {wasm_exec, indirect_out, _}} ->
            tally(Owner, maps:update_with(indirect, fun(N) -> N + 1 end, 1,
                                          Acc));
        done -> Owner ! {tally, Acc};
        _ -> tally(Owner, Acc)
    end.

check_counts(#{failed := 0, crashed := 0, compiled := C}, Excl) ->
    case 223 - length(Excl) of
        C -> ok;
        Want -> erlang:error({compiled, C, want, Want})
    end;
check_counts(Other, _) -> erlang:error({counts, Other}).

%% The guest's standard output, collected in the process that runs it.
imports(Cfg, Pid) ->
    wasi_preview1:imports(Cfg#{stdout => fun(B) -> Pid ! {out, B}, ok end}).

check_output() ->
    case iolist_to_binary(drain([])) of
        ?EXPECTED -> ok;
        Got -> erlang:error({output, Got})
    end.

drain(Acc) ->
    receive {out, B} -> drain([Acc, B]) after 0 -> Acc end.

in_process(F) ->
    Self = self(), Ref = make_ref(),
    {_, Mon} = spawn_monitor(fun() -> Self ! {Ref, F()} end),
    receive
        {Ref, R} -> demonitor(Mon, [flush]), R;
        {'DOWN', Mon, _, _, Why} -> erlang:error({run_died, Why})
    end.

qjs() ->
    {ok, B} = file:read_file("/Users/benoitc/Projects/erlang_wasm/test/fixtures/lang/qjs.wasm"),
    {ok, M} = wasm:compile(B),
    Dir = filename:join(["/tmp", "wasm-realbench"]),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "bench.js"),
                         <<"var a=0; for (var i=0;i<30000;i++) "
                           "{ a=(a+i*3)^(a>>>7); } print(a);">>),
    {M, #{args => [~"qjs", ~"/s/bench.js"], env => #{},
          dirs => [{~"/s", Dir, read}],
          clocks => [monotonic, realtime], random => strong,
          stderr => fun(_) -> ok end}}.
