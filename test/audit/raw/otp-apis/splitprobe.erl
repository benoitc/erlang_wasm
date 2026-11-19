-module(splitprobe).
-export([run/1]).
%% Start one worker of a guest with extra compile limits, and run requests
%% until the tier has compiled, so `split/2' runs and logs.
run([Guest, Extra]) ->
    Dir = filename:absname("_build/splitprobe"),
    ok = filelib:ensure_path(filename:join(Dir, "images")),
    _ = application:load(wasm),
    ok = application:set_env(wasm, snapshot_dir, filename:join(Dir, "images")),
    ok = application:set_env(wasm, code_cache_dir, filename:join(Dir, "code-" ++ Guest ++ Extra)),
    {ok, _} = application:ensure_all_started(wasm),
    {Adapter, Opts, Request} = reqbench:guest(list_to_atom(Guest)),
    {ok, Toks, _} = erl_scan:string(Extra ++ "."),
    {ok, More} = erl_parse:parse_term(Toks),
    Limits = maps:merge(maps:get(limits, Opts), More),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts#{limits => Limits}),
    [begin _ = wasm_script_worker:run(W, Request), timer:sleep(200) end
     || _ <- lists:seq(1, 40)],
    io:format("~s ~s: ~p~n", [Guest, Extra, wasm_jit:counts()]),
    erlang:halt(0).
