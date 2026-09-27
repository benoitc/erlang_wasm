-module(reqbench).
-moduledoc """
Requests a second through a pool of script workers, and which node-wide
processes they queue behind.

Use it when you change anything a request touches on its way through
`wasm_script_worker`: the reaper, the keeper, the code slots, staging. It is
the shape hornbeam serves in, a pool of workers each holding a captured image
and many callers taking whichever worker is free.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/reqbench.erl
    erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \\
        -run reqbench main py 14 64 10 ""

Arguments: the guest (`py`, `qjs`, `lua`), the worker count, the caller
count, the seconds to drive, and the extra worker options as an Erlang term
(`""` for none, `"#{restore_ahead => true}"` for example).

Every 10 ms it samples the message queue of each named process a request can
wait on, and it reports the maximum and the mean alongside how busy the
normal and dirty I/O schedulers were. A queue that grows is a serialisation
point; one that stays at 0 or 1 is not.

**Read `uptime` first.** A throughput number from a busy box is noise.
""".

-export([main/1, guest/1]).

-define(WATCHED, [file_server_2, wasm_worker_reaper, wasm_cleanup_manager,
                  wasm_cleanup_steward_sup, wasm_keeper, wasm_code_slots,
                  reqbench_pool]).

main([Guest, Workers, Callers, Seconds, Extra]) ->
    try run(list_to_atom(Guest), list_to_integer(Workers),
            list_to_integer(Callers), list_to_integer(Seconds), term(Extra))
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

term("") -> #{};
term(S) ->
    {ok, Toks, _} = erl_scan:string(S ++ "."),
    {ok, T} = erl_parse:parse_term(Toks),
    T.

run(Guest, NW, NC, Secs, Extra) ->
    Dir = filename:absname("_build/reqbench"),
    ok = filelib:ensure_path(filename:join(Dir, "images")),
    _ = application:load(wasm),
    ok = application:set_env(wasm, snapshot_dir, filename:join(Dir, "images")),
    ok = application:set_env(wasm, code_cache_dir, filename:join(Dir, "code")),
    {ok, _} = application:ensure_all_started(wasm),
    {Adapter, Opts, Request} = guest(Guest),
    T0 = erlang:monotonic_time(millisecond),
    Ws = start_workers(Adapter, maps:merge(Opts, Extra), NW),
    io:format("~p workers up in ~p ms~n",
              [NW, erlang:monotonic_time(millisecond) - T0]),
    {ok, #{}} = check(wasm_script_worker:run(hd(Ws), Request)),
    Pool = start_pool(Ws),
    %% Warm: every worker adopts the compiled tier before anything is timed.
    _ = drive(Pool, Request, NW, warm_ms(NW)),
    io:format("warm; jit ~p~n", [wasm_jit:counts()]),
    [begin
         _ = erlang:system_flag(scheduler_wall_time, true),
         W0 = erlang:statistics(scheduler_wall_time_all),
         Sampler = spawn_link(fun() -> sample(#{}, 0) end),
         Msacc = os:getenv("REQBENCH_MSACC") =/= false andalso C > 1,
         Msacc andalso msacc:start(),
         {Done, Lat} = drive(Pool, Request, C, Secs * 1000),
         Msacc andalso begin msacc:stop(), msacc:print() end,
         Sampler ! {stop, self()},
         Queues = receive {queues, Q, N} -> {Q, N} end,
         W1 = erlang:statistics(scheduler_wall_time_all),
         report(C, Done, Lat, Secs, Queues, busy(W0, W1))
     end || C <- [1, NC]],
    ok.

%% `REQBENCH_WARM' in seconds. The tier takes minutes to reach hot code on
%% CPython the first time; after that the code cache answers in seconds.
warm_ms(NW) ->
    case os:getenv("REQBENCH_WARM") of
        false -> 3_000 + NW * 500;
        S     -> list_to_integer(S) * 1000
    end.

check({ok, #{result := _}} = R) -> {ok, #{}} = {element(1, R), #{}};
check(Other) -> error({bad_request, Other}).

guest(py) ->
    Lang = "test/fixtures/lang/",
    Limits = maps:merge((wasm_python:limits())#{max_heap_words => 32 * 1024 * 1024},
                        #{compile => true, compile_quality => baseline,
                          compile_after => 1}),
    {wasm_python,
     #{path => Lang ++ "py_reactor.wasm", lib => Lang ++ "py_reactor_lib",
       root => scratch, capture_timeout => 300_000, limits => Limits,
       runner_min_heap_words => 1_000_000, capture_min_heap_words => 2_000_000},
     #{source => ~"def main(c):\n    return {'doubled': c['n'] * 2}\n",
       context => #{~"n" => 21}}};
guest(qjs) ->
    {wasm_javascript,
     #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch,
       limits => #{compile => true, compile_after => 1}},
     #{source => ~"export function main(c) { return {doubled: c.n * 2}; }",
       context => #{~"n" => 21}}};
guest(lua) ->
    {wasm_lua,
     #{path => "test/fixtures/lang/lua_reactor.wasm", root => scratch,
       limits => #{compile => true, compile_after => 1}},
     #{source => ~"function main(c) return {doubled = c.n * 2} end",
       context => #{~"n" => 21}}}.

%% One at a time for the first, so the image is captured once and filed;
%% the rest read it.
start_workers(Adapter, Opts, N) ->
    {ok, W1} = wasm_script_worker:start_link(Adapter, Opts),
    Self = self(),
    Rest = [spawn_link(fun() ->
                               {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
                               unlink(W),
                               Self ! {up, self(), W}
                       end) || _ <- lists:seq(2, N)],
    [W1 | [receive {up, P, W} -> link(W), W end || P <- Rest]].

%%% ------------------------------------------------------------------ pool ---

start_pool(Ws) ->
    Pid = spawn_link(fun() -> pool(Ws, queue:new()) end),
    register(reqbench_pool, Pid),
    Pid.

%% Last in, first out by default, which is what hornbeam's pool does: a
%% worker that just finished is handed the next request at once. With
%% `REQBENCH_POOL=fifo' the idle workers rotate, so each one rests between
%% requests, which is the case `restore_ahead' is for.
pool(Idle, Waiting) ->
    Fifo = os:getenv("REQBENCH_POOL") =:= "fifo",
    receive
        {out, From} ->
            case Idle of
                [W | Rest] -> From ! {worker, W}, pool(Rest, Waiting);
                []         -> pool(Idle, queue:in(From, Waiting))
            end;
        {in, W} ->
            case queue:out(Waiting) of
                {{value, From}, Q} -> From ! {worker, W}, pool(Idle, Q);
                {empty, _} when Fifo -> pool(Idle ++ [W], Waiting);
                {empty, _}         -> pool([W | Idle], Waiting)
            end
    end.

drive(Pool, Request, NC, Ms) ->
    Until = erlang:monotonic_time(millisecond) + Ms,
    Self = self(),
    Ps = [spawn_link(fun() -> Self ! {done, self(), caller(Pool, Request, Until, 0, [])} end)
          || _ <- lists:seq(1, NC)],
    Rs = [receive {done, P, R} -> R end || P <- Ps],
    {lists:sum([N || {N, _} <- Rs]), lists:append([L || {_, L} <- Rs])}.

caller(Pool, Request, Until, N, Lat) ->
    case erlang:monotonic_time(millisecond) >= Until of
        true -> {N, Lat};
        false ->
            T0 = erlang:monotonic_time(microsecond),
            Pool ! {out, self()},
            W = receive {worker, X} -> X end,
            R = wasm_script_worker:run(W, Request),
            Pool ! {in, W},
            {ok, _} = check(R),
            caller(Pool, Request, Until, N + 1,
                   [erlang:monotonic_time(microsecond) - T0 | Lat])
    end.

%%% ------------------------------------------------------------ sampling ---

sample(Acc, N) ->
    receive {stop, From} -> From ! {queues, Acc, N}
    after 10 ->
        Acc1 = lists:foldl(
                 fun(Name, A) ->
                     L = case whereis(Name) of
                             undefined -> 0;
                             P -> case process_info(P, message_queue_len) of
                                      {_, Len} -> Len;
                                      undefined -> 0
                                  end
                         end,
                     {Max, Sum} = maps:get(Name, A, {0, 0}),
                     A#{Name => {max(Max, L), Sum + L}}
                 end, Acc, ?WATCHED),
        sample(Acc1, N + 1)
    end.

busy(W0, W1) ->
    Normal = erlang:system_info(schedulers),
    Dirty = erlang:system_info(dirty_cpu_schedulers),
    Pairs = lists:zip(lists:sort(W0), lists:sort(W1)),
    Util = fun(Ids) ->
                   {A, T} = lists:foldl(
                              fun({{I, A0, T0}, {I, A1, T1}}, {SA, ST}) ->
                                      case lists:member(I, Ids) of
                                          true -> {SA + A1 - A0, ST + T1 - T0};
                                          false -> {SA, ST}
                                      end
                              end, {0, 0}, Pairs),
                   round(100 * A / max(1, T))
           end,
    Io = lists:seq(Normal + Dirty + 1,
                   Normal + Dirty + erlang:system_info(dirty_io_schedulers)),
    {Util(lists:seq(1, Normal)), Util(Io)}.

report(C, Done, Lat, Secs, {Queues, N}, {Normal, Io}) ->
    Sorted = lists:sort(Lat),
    Pct = fun(P) -> case Sorted of
                        [] -> 0;
                        _ -> lists:nth(max(1, round(P * length(Sorted))), Sorted) div 1000
                    end
          end,
    io:format("~nclients ~p: ~p requests, ~.1f req/s, p50 ~p ms, p99 ~p ms, "
              "schedulers ~p% normal / ~p% dirty io~n",
              [C, Done, Done / Secs, Pct(0.5), Pct(0.99), Normal, Io]),
    [io:format("  ~-26s max ~3w  mean ~.2f~n",
               [Name, Max, Sum / max(1, N)])
     || Name <- ?WATCHED, {Max, Sum} <- [maps:get(Name, Queues, {0, 0})]],
    ok.
