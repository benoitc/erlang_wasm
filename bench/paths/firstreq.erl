-module(firstreq).
-moduledoc """
How soon a compiled worker's requests run compiled, with the code cache warm.

Use it when you change what a worker does at start or how the tier finds cached
code. One worker, in a fresh VM, over a code cache and a snapshot directory an
earlier VM filled: it reports how long `start_link/2` took, which request first
entered generated code and what that request cost, and then the steady
compiled request, and how long a second worker takes to start once the first
has made the module resident.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/firstreq.erl
    erl -noshell +S 10:10 -pa _build/test/lib/wasm/ebin -pa bench/paths \\
        -run firstreq main warm lua /abs/cache/dir compiled
    erl -noshell +S 10:10 -pa _build/test/lib/wasm/ebin -pa bench/paths \\
        -run firstreq main measure lua /abs/cache/dir compiled

Arguments: `warm` or `measure`, the guest (`lua`, `qjs`, `py`), a directory
under your home directory holding `code/` and `images/`, and how to ask for
the tier: `compiled` for `compiled => true`, which preloads in the
background, `wait` for that with `preload => wait`, and `limits` for the four
keys it sets, spelled out, which is the only way a build without the option can
ask. Requests are sent back to back, so under `compiled` the first compiled
request is the first one issued after the background load lands.

Every measured line prints `cached => N` from `wasm_jit:counts/0`; a line with
0 did not read the cache and measures a compile. **Read `uptime` first.**
""".

-export([main/1]).

-define(STEADY, 100).
-define(MAX_REQUESTS, 400).

main([Mode, Guest, Dir, How]) ->
    try run(list_to_atom(Mode), list_to_atom(Guest), Dir, list_to_atom(How))
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

run(Mode, Guest, Dir, How) ->
    _ = application:load(wasm),
    ok = application:set_env(wasm, snapshot_dir, filename:join(Dir, "images")),
    ok = application:set_env(wasm, code_cache_dir, filename:join(Dir, "code")),
    {ok, _} = application:ensure_all_started(wasm),
    %% `FIRSTREQ_LOADALL=1' loads every module of the application first, as
    %% an embedded-mode release does at boot. Without it the first request
    %% loads what it touches through the code server, and waits behind a
    %% preload that is loading an artifact there.
    os:getenv("FIRSTREQ_LOADALL") =:= "1" andalso
        begin
            {ok, Mods} = application:get_key(wasm, modules),
            ok = code:ensure_modules_loaded(Mods)
        end,
    {Adapter, Opts, Request} = guest(Guest, How),
    T0 = erlang:monotonic_time(microsecond),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    Start = erlang:monotonic_time(microsecond) - T0,
    case Mode of
        warm -> warm(W, Request, Dir);
        measure -> measure(W, Request, Start, Guest, How, Adapter, Opts)
    end.

%% Requests until an artifact and its manifest (if this build writes one) are
%% on disk and the module is resident, then a pause for the compile's own
%% store to finish.
warm(W, Request, Dir) ->
    Code = filename:join(Dir, "code"),
    Loop = fun Loop(N) ->
               {ok, _} = check(wasm_script_worker:run(W, Request)),
               case wasm_code_slots:resident() =/= [] orelse N > 20_000 of
                   true -> N;
                   false -> timer:sleep(20), Loop(N + 1)
               end
           end,
    N = Loop(1),
    timer:sleep(500),
    io:format("warmed after ~p requests; ~p files; jit ~p~n",
              [N, length(filelib:wildcard(filename:join(Code, "*"))),
               wasm_jit:counts()]).

measure(W, Request, Start, Guest, How, Adapter, Opts) ->
    T1 = erlang:monotonic_time(microsecond),
    {ok, _} = check(wasm_script_worker:run(W, Request)),
    Req1 = erlang:monotonic_time(microsecond) - T1,
    {First, FirstUs} = case maps:get(entered, wasm_jit:counts()) > 0 of
                           true -> {1, Req1};
                           false -> first_compiled(W, Request, 2)
                       end,
    Steady = [begin
                  T = erlang:monotonic_time(microsecond),
                  {ok, _} = check(wasm_script_worker:run(W, Request)),
                  erlang:monotonic_time(microsecond) - T
              end || _ <- lists:seq(1, ?STEADY)],
    S = lists:sort(Steady),
    %% A second worker on the same node, whose module is already resident.
    T2 = erlang:monotonic_time(microsecond),
    {ok, W2} = wasm_script_worker:start_link(Adapter, Opts),
    Start2 = erlang:monotonic_time(microsecond) - T2,
    ok = wasm_script_worker:stop(W2),
    io:format("RESULT guest=~p how=~p start_ms=~.1f start2_ms=~.1f "
              "req1_ms=~.1f first=~p first_ms=~.1f "
              "steady_min_ms=~.2f steady_p50_ms=~.2f steady_p99_ms=~.2f "
              "cached=~p~n",
              [Guest, How, Start / 1000, Start2 / 1000, Req1 / 1000,
               First, FirstUs / 1000,
               hd(S) / 1000, lists:nth(?STEADY div 2, S) / 1000,
               lists:nth(?STEADY * 99 div 100, S) / 1000,
               maps:get(cached, wasm_jit:counts())]).

%% The request number that first entered generated code, and what it took.
first_compiled(_W, _Request, N) when N > ?MAX_REQUESTS ->
    {never, 0};
first_compiled(W, Request, N) ->
    Before = maps:get(entered, wasm_jit:counts()),
    T = erlang:monotonic_time(microsecond),
    {ok, _} = check(wasm_script_worker:run(W, Request)),
    Us = erlang:monotonic_time(microsecond) - T,
    case maps:get(entered, wasm_jit:counts()) > Before of
        true -> {N, Us};
        false -> first_compiled(W, Request, N + 1)
    end.

check({ok, #{result := _}} = R) -> R;
check(Other) -> error({bad_request, Other}).

tier(compiled) -> {#{compiled => true}, #{}};
tier(wait) -> {#{compiled => true, preload => wait}, #{}};
tier(limits) ->
    {#{}, #{fuel => infinity, compile => true, compile_after => 1,
            compile_quality => baseline}}.

guest(G, How) ->
    {Opt, Tier} = tier(How),
    {Adapter, Opts, Request} = guest(G),
    Limits = maps:merge(maps:get(limits, Opts, #{}), Tier),
    {Adapter, maps:merge(Opts#{limits => Limits}, Opt), Request}.

guest(py) ->
    Lang = "test/fixtures/lang/",
    {wasm_python,
     #{path => Lang ++ "py_reactor.wasm", lib => Lang ++ "py_reactor_lib",
       root => scratch, capture_timeout => 300_000,
       limits => (wasm_python:limits())#{max_heap_words => 32 * 1024 * 1024},
       runner_min_heap_words => 1_000_000, capture_min_heap_words => 2_000_000},
     #{source => ~"def main(c):\n    return {'doubled': c['n'] * 2}\n",
       context => #{~"n" => 21}}};
guest(qjs) ->
    {wasm_javascript,
     #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch},
     #{source => ~"export function main(c) { return {doubled: c.n * 2}; }",
       context => #{~"n" => 21}}};
guest(lua) ->
    {wasm_lua,
     #{path => "test/fixtures/lang/lua_reactor.wasm", root => scratch},
     #{source => ~"function main(c) return {doubled = c.n * 2} end",
       context => #{~"n" => 21}}}.
