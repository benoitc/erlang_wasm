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
the tier: `compiled` for `compiled => true`, which loads cached code at start,
and `limits` for the four keys it sets, spelled out, which is the only way a
build without the option can ask. Requests are sent back to back.
`worst_before_ms` is the slowest request up to and including the first
compiled one.

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
    %% `FIRSTREQ_LOADALL=1' loads every module of `wasm', `stdlib' and
    %% `kernel' first, as an embedded-mode release does at boot. Without it a
    %% process loads what it touches through the code server, and while a
    %% large artifact is being prepared any such load waits for it: this
    %% harness's own first calls to `timer' or `io_lib_format' included.
    os:getenv("FIRSTREQ_LOADALL") =:= "1" andalso
        begin
            Mods = lists:append(
                     [M || A <- [wasm, stdlib, kernel],
                           {ok, M} <- [application:get_key(A, modules)]]),
            _ = code:ensure_modules_loaded(Mods),
            ok
        end,
    {Adapter, Opts, Request} = guest(Guest, How),
    T0 = erlang:monotonic_time(microsecond),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    Start = erlang:monotonic_time(microsecond) - T0,
    case Mode of
        warm -> warm(W, Request, Dir);
        measure -> measure(W, Request, Start, Guest, How, Adapter, Opts, T0)
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

measure(W, Request, Start, Guest, How, Adapter, Opts, T0) ->
    T1 = erlang:monotonic_time(microsecond),
    {ok, _} = check(wasm_script_worker:run(W, Request)),
    End1 = erlang:monotonic_time(microsecond),
    Req1 = End1 - T1,
    {First, FirstUs, WorstUs, Gap, Ready} =
        case entered() > 0 of
            true -> {1, Req1, Req1, 0, End1 - T0};
            false -> first_compiled(W, Request, 2, Req1, End1, 0, T0)
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
              "req1_ms=~.1f first=~p first_ms=~.1f worst_before_ms=~.1f "
              "caller_gap_ms=~.1f ready_ms=~.1f "
              "steady_min_ms=~.2f steady_p50_ms=~.2f steady_p99_ms=~.2f "
              "cached=~p~n",
              [Guest, How, Start / 1000, Start2 / 1000, Req1 / 1000,
               First, FirstUs / 1000, WorstUs / 1000, Gap / 1000,
               Ready / 1000,
               hd(S) / 1000, lists:nth(?STEADY div 2, S) / 1000,
               lists:nth(?STEADY * 99 div 100, S) / 1000,
               maps:get(cached, wasm_jit:counts())]).

%% The request number that first entered generated code, what it took, the
%% slowest request up to it, the longest time the caller spent between one
%% answer and its next request (it sends at once, so anything here is the
%% caller itself held up), and when the first compiled request answered,
%% counted from the start of `start_link/2'.
first_compiled(_W, _Request, N, Worst, _Prev, Gap, _T0)
  when N > ?MAX_REQUESTS ->
    {never, 0, Worst, Gap, 0};
first_compiled(W, Request, N, Worst, Prev, Gap, T0) ->
    Before = entered(),
    T = erlang:monotonic_time(microsecond),
    {ok, _} = check(wasm_script_worker:run(W, Request)),
    End = erlang:monotonic_time(microsecond),
    Us = End - T,
    Gap1 = max(Gap, T - Prev),
    case entered() > Before of
        true -> {N, Us, max(Worst, Us), Gap1, End - T0};
        false -> first_compiled(W, Request, N + 1, max(Worst, Us), End, Gap1,
                                T0)
    end.

%% `entered' from the counter `wasm_jit:counts/0' reads, without the rest of
%% what it builds, so the probe between two requests is two reads.
entered() -> counters:get(persistent_term:get({wasm_jit, hot}), 1).

check({ok, #{result := _}} = R) -> R;
check(Other) -> error({bad_request, Other}).

tier(compiled) -> {#{compiled => true}, #{}};
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
