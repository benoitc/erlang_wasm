-module(lowbench).
-moduledoc """
A request's wall time on a real guest, and what its first request costs.

Use this to measure anything a request pays for the module rather than for
its own work: lowering, the validation context, the function table. Every
request runs in a fresh runner process, so whatever a runner builds in its own
dictionary it builds again next time, and this is where that shows.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/lowbench.erl
    erl +S 10:10 -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run lowbench main Label Guest Tier Ahead WarmReqs WarmSecs N Out

`Guest` is `lua`, `qjs` or `py`; `Tier` is `off` or `on`; `Ahead` is the
worker's `restore_ahead`. The compiled tier caches code under
`~/.cache/lowering-bench/Label`, mode 0700; delete it when done.

The first request of a fresh node is reported on its own, with the time the
runner spent in `wasm:share_ir/1` (zero where it does not exist) and
the `persistent_term` words that request added, because that is where a
module's lowered bodies are published. Then `WarmReqs` requests and at least
`WarmSecs` seconds of warm-up, then `N` timed requests. `Out` gets one term
with every wall time; compare two builds by interleaving fresh VMs, as
`bench/paths/README.md` says.
""".
-export([main/1]).

main([Label, Guest, Tier, Ahead, WarmN, WarmS, N, Out]) ->
    try run(Label, list_to_atom(Guest), list_to_atom(Tier),
            list_to_atom(Ahead), list_to_integer(WarmN),
            list_to_integer(WarmS), list_to_integer(N), Out)
    catch C:R:St -> io:format("failed: ~p~n~p~n", [{C, R}, St])
    end,
    erlang:halt(0).

run(Label, Guest, Tier, Ahead, WarmN, WarmS, N, Out) ->
    Root = filename:join([os:getenv("HOME"), ".cache", "lowering-bench"]),
    Code = filename:join(Root, Label),
    ok = filelib:ensure_path(Code),
    ok = file:change_mode(Root, 8#700),
    ok = file:change_mode(Code, 8#700),
    Dir = filename:absname("_build/lowbench"),
    ok = filelib:ensure_path(filename:join(Dir, "images")),
    _ = application:load(wasm),
    ok = application:set_env(wasm, snapshot_dir, filename:join(Dir, "images")),
    ok = application:set_env(wasm, code_cache_dir, Code),
    {ok, _} = application:ensure_all_started(wasm),
    {Adapter, Opts0, Request} = guest(Guest, Tier),
    {ok, W} = wasm_script_worker:start_link(Adapter,
                                            Opts0#{restore_ahead => Ahead}),
    First = first(W, Request),
    Until = erlang:monotonic_time(millisecond) + WarmS * 1000,
    Warm = warm(W, Request, WarmN, Until, 1),
    Walls = [wall(W, Request) || _ <- lists:seq(1, N)],
    ok = file:write_file(Out, io_lib:format("~p.~n",
        [#{label => Label, guest => Guest, tier => Tier, ahead => Ahead,
           warm => Warm, jit => wasm_jit:counts(), first => First,
           module_bytes => maps:get(bytes, wasm_module_cache:stats()),
           uptime => os:cmd("uptime"), walls => Walls}])),
    S = lists:sort(Walls),
    io:format("~s ~p ~p ahead=~p: first ~p us min ~p med ~p us~n",
              [Label, Guest, Tier, Ahead, maps:get(wall, First), hd(S),
               lists:nth(length(S) div 2 + 1, S)]).

%% The first request, with the publish timed from trace timestamps in whatever
%% process destroys the instance.
first(W, Request) ->
    Words = fun() -> maps:get(memory, persistent_term:info()) div 8 end,
    P0 = Words(),
    Traced = erlang:trace_pattern({wasm, share_ir, 1},
                                  [{'_', [], [{return_trace}]}], [local]),
    _ = erlang:trace(new_processes, true, [call, monotonic_timestamp]),
    T0 = erlang:monotonic_time(microsecond),
    {ok, _} = check(wasm_script_worker:run(W, Request)),
    T1 = erlang:monotonic_time(microsecond),
    _ = erlang:trace(new_processes, false, [call]),
    _ = erlang:trace_pattern({wasm, share_ir, 1}, false, [local]),
    #{wall => T1 - T0, traced => Traced, publish_us => publish_us(0),
      pt_words => Words() - P0}.

publish_us(Acc) ->
    receive
        {trace_ts, P, call, {wasm, share_ir, _}, T0} ->
            receive
                {trace_ts, P, return_from, {wasm, share_ir, 1}, _,
                 T1} ->
                    publish_us(Acc + erlang:convert_time_unit(
                                       T1 - T0, native, microsecond))
            after 5000 -> Acc
            end
    after 0 -> Acc
    end.

warm(W, Req, N, Until, K) ->
    case K >= N andalso erlang:monotonic_time(millisecond) >= Until of
        true -> K;
        false -> {ok, _} = check(wasm_script_worker:run(W, Req)),
                 warm(W, Req, N, Until, K + 1)
    end.

wall(W, Req) ->
    T0 = erlang:monotonic_time(microsecond),
    R = wasm_script_worker:run(W, Req),
    T1 = erlang:monotonic_time(microsecond),
    {ok, _} = check(R),
    T1 - T0.

check({ok, #{result := _}} = R) -> {ok, R};
check(Other) -> error({bad_request, Other}).

tier(off, L) -> maps:without([compile, compile_after, compile_quality], L);
tier(on, L) -> L#{fuel => infinity, compile => true, compile_after => 1,
                  compile_quality => baseline}.

guest(py, T) ->
    Lang = "test/fixtures/lang/",
    Limits = tier(T, (wasm_python:limits())#{max_heap_words => 32 * 1024 * 1024}),
    {wasm_python,
     #{path => Lang ++ "py_reactor.wasm", lib => Lang ++ "py_reactor_lib",
       root => scratch, capture_timeout => 300_000, limits => Limits,
       runner_min_heap_words => 1_000_000, capture_min_heap_words => 2_000_000},
     #{source => ~"def main(c):\n    return {'doubled': c['n'] * 2}\n",
       context => #{~"n" => 21}}};
guest(qjs, T) ->
    {wasm_javascript,
     #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch,
       limits => tier(T, #{timeout => 30_000, fuel => infinity,
                           max_memory_pages => 4096,
                           max_heap_words => 16 * 1024 * 1024})},
     #{source => ~"export function main(c) { return {doubled: c.n * 2}; }",
       context => #{~"n" => 21}}};
guest(lua, T) ->
    {wasm_lua,
     #{path => "test/fixtures/lang/lua_reactor.wasm", root => scratch,
       limits => tier(T, #{})},
     #{source => ~"function main(c) return {doubled = c.n * 2} end",
       context => #{~"n" => 21}}}.
