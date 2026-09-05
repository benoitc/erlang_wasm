-module(adopt).
-moduledoc """
Whether a one-call guest can ever reach generated code.

`wasm_jit:maybe_adopt/3` says a call that finds nothing resident sets an ask,
interprets, and the module is adopted *on a later call*. Every `wasm32-wasi`
command-line program is one call, `_start`, so the question is whether a second
*instance* in the same emulator picks up what the first one asked for.

This watches rather than assumes. It prints `wasm_jit:counts/0` after every
step, so `compiled` and `entered` say what happened instead of a wall time
being read as evidence:

    erlc -I _build/default/lib -o bench/paths bench/paths/adopt.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run adopt main <guest.wasm> <script-dir> [seconds] [cache-dir]

Output is written as it happens. Do not pipe it through `tail`, which buffers
until exit and hides exactly the progress this exists to show.
""".

-export([main/1]).

-define(REQUEST, <<"{\"name\": \"ada\"}\n">>).

main([Guest, Dir]) -> main([Guest, Dir, "180", "", "load"]);
main([Guest, Dir, Secs]) -> main([Guest, Dir, Secs, "", "load"]);
main([Guest, Dir, Secs, Cache]) -> main([Guest, Dir, Secs, Cache, "load"]);
main([Guest, Dir, Secs, Cache, How]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Cache =:= "" orelse application:set_env(wasm, code_cache_dir, Cache),
    {ok, Bin} = file:read_file(Guest),
    %% Three ways in. `load' puts the module in `persistent_term'; `compile'
    %% keeps it on this process's heap and, with no identity,
    %% `wasm_code_cache:key/6' refuses it, so nothing it compiles is ever kept.
    %% `hashed' is the interesting one: on the heap like `compile', and named by
    %% its content hash like `load', which is the pair the cache actually needs.
    {ok, Mod} =
        case How of
            "load" -> wasm:load(Bin);
            "compile" -> wasm:compile(Bin);
            "hashed" ->
                wasm:compile(Bin, #{identity => {sha256, crypto:hash(sha256, Bin)}})
        end,
    io:format("module in by ~s~n", [How]),
    say("start", 0),

    %% One call, which is all a `_start' guest ever makes. `after_call/2' runs
    %% inside `wasm:call/3' at depth 0, so the ask is raised here and not lost
    %% when this process moves on.
    {T1, R1} = run(Mod, Dir),
    io:format("call 1: ~w ms, reply ~p~n", [T1, R1]),
    say("after call 1", 0),

    %% Watch for the compiler. If `compiled' never moves, nothing was ever
    %% queued and the disk cache can never be filled by this shape of workload.
    Waited = watch(list_to_integer(Secs)),

    %% A fresh instance of the same module: this is the one that could adopt.
    {T2, R2} = run(Mod, Dir),
    io:format("call 2: ~w ms, reply ~p~n", [T2, R2]),
    say("after call 2", Waited),

    io:format("~ncache dir holds ~w file(s)~n",
              [length(filelib:wildcard(filename:join(
                        application:get_env(wasm, code_cache_dir, "/nonexistent"),
                        "*.beam")))]),
    init:stop().

%% Poll rather than sleep, so the moment compilation lands is visible.
watch(Secs) ->
    watch(Secs * 4, 0).

watch(0, N) ->
    io:format("gave up after ~w s~n", [N div 4]),
    N div 4;
watch(Left, N) ->
    timer:sleep(250),
    case wasm_jit:counts() of
        #{compiled := C} when C > 0 ->
            io:format("compiled after ~w s~n", [(N + 1) div 4]),
            (N + 1) div 4;
        _ -> watch(Left - 1, N + 1)
    end.

say(When, _) ->
    io:format("  ~-14s ~p~n", [When, wasm_jit:counts()]).

run(Mod, Dir) ->
    %% Both calls run in this process, so the stdin fun's "already sent" flag
    %% has to be cleared or the second call reads end of file at once, exits in
    %% milliseconds and reports no reply. That is a harness bug that reads
    %% exactly like a 16x speedup.
    _ = erase(sent), _ = erase(buf), _ = erase(line),
    Wasi = #{args => argv(Dir),
             dirs => [{~"/app", Dir, read}],
             stdin => fun(_) -> once(?REQUEST) end,
             stdout => fun(D) -> line(D) end,
             stderr => fun(_) -> ok end},
    {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                               #{max_memory_pages => 4096, compile => true,
                                 compile_after => 1}),
    T0 = erlang:monotonic_time(millisecond),
    _ = wasm:call(I, ~"_start", []),
    T = erlang:monotonic_time(millisecond) - T0,
    ok = wasm:destroy(I),
    {T, erase(line)}.

argv(Dir) ->
    case filelib:is_regular(filename:join(Dir, "worker.py")) of
        true -> [~"python", ~"-u", ~"/app/worker.py"];
        false -> [~"qjs", ~"/app/worker.js"]
    end.

once(Data) ->
    case get(sent) of
        undefined -> put(sent, true), {ok, Data};
        true -> eof
    end.

line(Data) ->
    B = <<(case get(buf) of undefined -> <<>>; X -> X end)/binary,
          (iolist_to_binary(Data))/binary>>,
    case binary:split(B, ~"\n") of
        [L, Rest] -> put(line, L), put(buf, Rest);
        [_] -> put(buf, B)
    end,
    ok.
