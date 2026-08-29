-module(p6_pd).
-export([run/0]).

%% A long-lived process that CALLS instances but never instantiates one.
%% Does anything ever reclaim its per-process caches?
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file("test/fixtures/lang/qjs.wasm"),
    {ok, Mod} = wasm:compile(Bin),
    Caller = spawn(fun caller/0),
    [begin
         Owner = self(),
         {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(#{})),
         Caller ! {call, I, Owner},
         receive done -> ok after 60000 -> exit(slow) end,
         ok = wasm:destroy(I),
         case N rem 50 of
             0 -> report(N, Caller);
             _ -> ok
         end
     end || N <- lists:seq(1, 300)],
    io:format("~nAfter 300 instances, all destroyed by their owner:~n"),
    report(300, Caller),
    ok.

caller() ->
    receive
        {call, I, From} ->
            _ = catch wasm:call(I, ~"_start", []),
            From ! done,
            caller()
    end.

report(N, P) ->
    {dictionary, D} = process_info(P, dictionary),
    {memory, M} = process_info(P, memory),
    Ir = length([1 || {{wasm_ir, _, _}, _} <- D]),
    Mut = length([1 || {{wasm_mut_cache, _}, _} <- D]),
    Inst = length([1 || {{wasm_inst, _}, _} <- D]),
    io:format("after ~2w instances: caller dict=~5w (ir=~5w mut=~3w inst=~3w) heap=~.1f MB~n",
              [N, length(D), Ir, Mut, Inst, M / 1048576]).
