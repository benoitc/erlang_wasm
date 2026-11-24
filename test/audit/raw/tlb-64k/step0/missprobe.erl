-module(missprobe).
%% PR C step 0: calls into the generated miss functions, and how many of them
%% were second-entry hits, during one warm compiled QuickJS _start. Untimed.
-include("wasm.hrl").
-include("wasm_validate.hrl").
-include("wasm_exec.hrl").
-export([main/0]).
main() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, B} = file:read_file("test/fixtures/lang/qjs.wasm"),
    {ok, M} = wasm:compile(B),
    Dir = "/tmp/wasm-realbench", ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "bench.js"),
        <<"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); } print(a);">>),
    Self = self(),
    Im = fun() -> wasi_preview1:imports(#{args => [<<"qjs">>, <<"/s/bench.js">>], env => #{},
              dirs => [{<<"/s">>, Dir, read}], clocks => [monotonic, realtime],
              random => strong, stdout => fun(X) -> Self ! {out, X}, ok end,
              stderr => fun(_) -> ok end}) end,
    Opts = #{compile => true, compile_after => 1},
    {ok, I} = wasm:instantiate(M, Im(), Opts),
    {ok, _} = wasm:call(I, <<"_start">>, []),
    {ok, J} = wasm:instantiate(M, Im(), Opts),
    ok = wasm_jit:await(J, 1800000),
    _ = drain(),
    Mod = wasm_code_slots:slot_module(wasm_instance:code_slot(J)),
    Miss = [{Mod, F, A} || {F, A} <- erlang:get_module_info(Mod, functions),
                           lists:prefix("wasm_m_", atom_to_list(F))],
    Keys = Miss ++ [{wasm_probe, hit2, 0}, {wasm_exec, run, 3}],
    {ok, Q} = wasm:instantiate(M, Im(), Opts),
    {module, wasm_probe} = code:ensure_loaded(wasm_probe),
    [1 = erlang:trace_pattern(K, true, [call_count]) || K <- Keys],
    {ok, _} = wasm:call(Q, <<"_start">>, []),
    Out = iolist_to_binary(drain()),
    C = fun(K) -> {call_count, N} = erlang:trace_info(K, call_count), N end,
    MissCalls = lists:sum([C(K) || K <- Miss]),
    io:format("~p.~n", [#{miss_calls => MissCalls, second_entry_hits => C({wasm_probe, hit2, 0}),
                         interpreter_dispatch => C({wasm_exec, run, 3}),
                         output_ok => Out =:= <<"864318946\n">>, jit => wasm_jit:counts()}]),
    halt().
drain() -> receive {out, X} -> [X | drain()] after 0 -> [] end.
