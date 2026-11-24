-module(startalloc).
%% PR C allocation gate: words allocated by the process running one warm
%% compiled QuickJS _start, from allocwords' collection-trace estimator, with
%% the instance made in the same process before the window. Output checked.
-export([main/0]).
main() ->
    ok = allocwords:validate(),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, B} = file:read_file("test/fixtures/lang/qjs.wasm"),
    {ok, M} = wasm:compile(B),
    Dir = "/tmp/wasm-realbench", ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "bench.js"),
        <<"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); } print(a);">>),
    Im = fun(P) -> wasi_preview1:imports(#{args => [<<"qjs">>, <<"/s/bench.js">>], env => #{},
              dirs => [{<<"/s">>, Dir, read}], clocks => [monotonic, realtime],
              random => strong, stdout => fun(X) -> P ! {out, X}, ok end,
              stderr => fun(_) -> ok end}) end,
    Opts = #{compile => true, compile_after => 1},
    Self = self(),
    {ok, I} = wasm:instantiate(M, Im(Self), Opts),
    {ok, _} = wasm:call(I, <<"_start">>, []),
    {ok, J} = wasm:instantiate(M, Im(Self), Opts),
    ok = wasm_jit:await(J, 1800000),
    R = allocwords:measure(fun() -> {ok, Q} = wasm:instantiate(M, Im(self()), Opts), Q end,
                           fun(Q) -> {ok, _} = wasm:call(Q, <<"_start">>, []),
                                     Out = iolist_to_binary(drain()),
                                     ok = wasm:destroy(Q), Out end,
                           600000),
    io:format("~p.~n", [R#{jit => wasm_jit:counts()}]),
    halt().
drain() -> receive {out, X} -> [X | drain()] after 0 -> [] end.
