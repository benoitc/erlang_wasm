-module(realbench).
-moduledoc """
Real compiler output, not the synthetic loop.

Use this to check that a change measured on `bench/cross/loop.wat` transfers.
That loop is fifteen instructions of i32 arithmetic chosen to be easy to reason
about; QuickJS and the Rust plugin are what clang and rustc actually emit, and
a change can help one and not the other.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/realbench.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run realbench main qjs
""".
-export([main/1]).

main([Arm]) -> main([Arm, "off"]);
main([Arm, Tier]) ->
    {ok, _} = application:ensure_all_started(wasm),
    put(opts, case Tier of
                  "off" -> #{};
                  %% One, because a benchmark that instantiates a handful of
                  %% times would otherwise never reach the default threshold and
                  %% would report the interpreter under another name.
                  "on" -> #{compile => true, compile_after => 1}
              end),
    run(list_to_atom(Arm)),
    case get(opts) of
        #{compile := true} -> io:format("  ~p~n", [wasm_jit:counts()]);
        _ -> ok
    end,
    init:stop().

%% The tier is a per-instance option, so it goes in wherever an instance is
%% built rather than being set globally.
opts() -> get(opts).

fixture(Parts) ->
    {ok, B} = file:read_file(filename:join(["test", "fixtures" | Parts])),
    {ok, M} = wasm:compile(B),
    M.

best(N, F) ->
    lists:min([element(1, timer:tc(F)) || _ <- lists:seq(1, N)]).

%% Every run in its own process, and every result reported rather than the
%% minimum.
%%
%% Both halves are load bearing, and `bench/paths/matrix.erl' is what
%% established them. Repeating QuickJS in one process makes its runs bimodal:
%% about 1.7 seconds when the garbage collector handles the interpreter's
%% 10-million-word heap cheaply and about 13 when it does not, a 420x difference
%% in collection time against identical reductions and byte-identical output.
%% A fresh process per run takes the spread to 1.02x.
%%
%% A minimum across that reports whichever run happened to be cheapest, so two
%% arms can differ by 7x while doing the same work at the same speed. The 1.33x
%% this arm once reported for the compiled tier was exactly that.
each(N, F) ->
    [element(1, timer:tc(fun() -> benchlib:in_process([opts], F) end)) || _ <- lists:seq(1, N)].

%% With the tier on, run once to make the module hot and then wait for the
%% compiler. With it off there is nothing to wait for and this is one extra
%% interpreted run, which is a warm-up either way.
warm(M, Imports) ->
    benchlib:in_process([opts], fun() ->
        {ok, I} = wasm:instantiate(M, Imports, opts()),
        _ = wasm:call(I, ~"_start", []),
        R = case opts() of
                #{compile := true} ->
                    {ok, J} = wasm:instantiate(M, Imports, opts()),
                    Got = wasm_jit:await(J, 600000),
                    ok = wasm:destroy(J),
                    Got;
                _ -> ok
            end,
        ok = wasm:destroy(I),
        R
    end).

warm_export(M, Imports, Name) ->
    benchlib:in_process([opts], fun() ->
        {ok, I} = wasm:instantiate(M, Imports, opts()),
        _ = [wasm:call(I, Name, []) || _ <- lists:seq(1, 40)],
        R = case opts() of
                #{compile := true} -> wasm_jit:await(I, 600000);
                _ -> ok
            end,
        ok = wasm:destroy(I),
        R
    end).


script_dir() ->
    Dir = filename:join(["/tmp", "wasm-realbench"]),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "bench.js"), script()),
    Dir.

%% A compute-bound script, so the number is the interpreter running QuickJS
%% running JavaScript, not WASI doing file I/O.
script() ->
    ~"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); } print(a);".

run(qjs) ->
    M = fixture(["lang", "qjs.wasm"]),
    %% This build takes a FILE and nothing else -- `qjs --help' says
    %% `qjs FILE [ARG ...]' and lists no `-e'. So the script is written out and
    %% handed over through a preopened directory, which is also the only way
    %% this module gets a filesystem at all.
    Dir = script_dir(),
    Cfg = #{args => [~"qjs", ~"/s/bench.js"], env => #{},
            dirs => [{~"/s", Dir, read}],
            clocks => [monotonic, realtime], random => strong,
            stdout => fun(_) -> ok end, stderr => fun(_) -> ok end},
    %% Asserted, not ignored. This arm reported a number for a run that exited
    %% with a WASI usage error for as long as it has existed, because the result
    %% of `_start' was discarded: it was timing an argument-parsing failure and
    %% calling it 300,000 JavaScript iterations. As a deterministic workload it
    %% still detected regressions, which is why what it caught was real, but the
    %% label was a lie and a benchmark that cannot fail will tell it again.
    %% Compilation happens off the calling process now, so an arm that just
    %% starts calling measures the interpreter while a compiler runs beside it.
    %% Warm first, which is what an embedder serving from a long-lived instance
    %% does, and what makes the two arms comparable at all.
    ok = warm(M, wasi_preview1:imports(Cfg)),
    Ts = each(3, fun() ->
            {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg), opts()),
            case wasm:call(I, ~"_start", []) of
                {ok, _} -> ok;
                {error, E} -> erlang:error({qjs_did_not_run, E})
            end,
            ok = wasm:destroy(I)
        end),
    %% Compare run 1 against run 1 and run 2 against run 2. Comparing across
    %% that boundary compares the node's state, not the change under test.
    [io:format("qjs-30k-js-iterations run ~p\t~.1f ms~n", [N, T / 1000])
     || {N, T} <- lists:enumerate(Ts)];

%% The Rust plugin, called through an export rather than through `_start': it is
%% 74% compilable where QuickJS is 55%, and it is what a plugin workload looks
%% like.
run(plugin) ->
    M = fixture(["plugin", "plugin.wasm"]),
    Im = wasi_preview1:imports(#{}),
    {ok, I} = wasm:instantiate(M, Im, opts()),
    Name = ~"capacity",
    #{Name := {func, _}} = wasm:exports(I),
    ok = wasm:destroy(I),
    %% As the qjs arm: warm before measuring, or this times the interpreter
    %% while a compiler it will never wait for runs beside it. Two hundred calls
    %% of three microseconds finish long before a module compiles.
    ok = warm_export(M, Im, Name),
    T = best(5, fun() ->
            {ok, J} = wasm:instantiate(M, Im, opts()),
            _ = [wasm:call(J, Name, []) || _ <- lists:seq(1, 200)],
            ok = wasm:destroy(J)
        end),
    io:format("plugin-~s-x200\t~.1f us~n", [Name, T / 1.0]);

run(exports) ->
    M = fixture(["plugin", "plugin.wasm"]),
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{})),
    io:format("~p~n", [wasm:exports(I)]).
