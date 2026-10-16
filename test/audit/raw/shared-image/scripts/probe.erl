-module(probe).
-export([main/1]).
%% Where a worker start goes: the artifact, then the rest, one worker, from
%% the filed image (scratch diagnostic, never a gate sample).
main([G]) ->
    Name = list_to_atom(G),
    ok = reactorlib:page_limit(65536),
    ok = application:set_env(wasm, snapshot_dir, filename:absname("_build/densitybench/images")),
    {Adapter, Opts} = reactorlib:worker_opts(Name, 120000),
    [begin
         T0 = erlang:monotonic_time(microsecond),
         {ok, _} = Adapter:artifact(Opts),
         T1 = erlang:monotonic_time(microsecond),
         {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
         T2 = erlang:monotonic_time(microsecond),
         unlink(W), ok = wasm_script_worker:stop(W), timer:sleep(300),
         io:format("artifact ~p us, start ~p us~n", [T1 - T0, T2 - T1])
     end || _ <- lists:seq(1, 4)],
    halt().
