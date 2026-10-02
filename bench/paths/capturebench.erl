-module(capturebench).
-moduledoc """
What capturing an image costs: `wasm:snapshot/2` alone, and a whole worker
start.

Use it to hold a change to capture against the snapshot and worker start
gates. The two are timed apart because a worker start contains a capture and
the capture contains a snapshot, and a gate on one must not be read off the
other.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
         bench/paths/reactorlib.erl bench/paths/capturebench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run capturebench main snapshot py,py_entry 3 5 raw/snapshot.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run capturebench main worker py,py_entry 3 raw/worker.terms

## `snapshot`

Arguments: the guests, the rounds, the repeats, and the raw file (`none` for
no file). Each round initialises a fresh instance the way a worker's capture
does (instantiate under the adapter's declaration, run its `init` list, pass
its `validate`) in a process with the capture heap floor, then times
`wasm:snapshot/2` from the call to its return. The first snapshot of each
instance is the gate sample. The repeats snapshot the same instance again and
are reported apart, because a snapshot that changes the instance it captures
would make a repeat cheaper than a first.

## `worker`

Arguments: the guests, the starts, and the raw file. Each start points
`snapshot_dir` at a new empty directory, so it boots, captures and files, and
times `wasm_script_worker:start_link/2` from the call to `{ok, W}`. The file
is checked to be there before the sample counts. A CPython start is about
twenty seconds.
""".

-export([main/1]).

main([Mode | Args]) ->
    try
        ok = reactorlib:page_limit(65536),
        Meta = reactorlib:meta(),
        io:format("# ~s~n", [maps:get(uptime, Meta)]),
        run(Mode, Args, Meta),
        io:format("# ~s~n", [reactorlib:uptime_now()])
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

run("snapshot", [Gs, Rounds, Repeats, Raw0], Meta) ->
    Raw = raw(Raw0),
    ok = reactorlib:write_raw(Raw, {meta, capturebench_snapshot, Meta}),
    [snapshot_arm(G, list_to_integer(Rounds), list_to_integer(Repeats), Raw)
     || G <- guests(Gs)],
    ok;
run("worker", [Gs, N, Raw0], Meta) ->
    Raw = raw(Raw0),
    ok = reactorlib:write_raw(Raw, {meta, capturebench_worker, Meta}),
    [worker_arm(G, list_to_integer(N), Raw) || G <- guests(Gs)],
    ok.

guests(S) -> [list_to_atom(A) || A <- string:lexemes(S, ",")].

raw("none") -> none;
raw(P) -> P.

%%% ------------------------------------------------------------- snapshot ---

snapshot_arm(Name, Rounds, Repeats, Raw) ->
    {ok, G} = reactorlib:guest(Name),
    Rows = [snapshot_round(G, Repeats) || _ <- lists:seq(1, Rounds)],
    First = [F || {F, _} <- Rows],
    Again = lists:append([R || {_, R} <- Rows]),
    show(Name, "snapshot first", First),
    Again =/= [] andalso show(Name, "snapshot repeat", Again),
    ok = reactorlib:write_raw(Raw, {snapshot, Name, #{first => First,
                                                      repeat => Again}}).

%% In a child with the floor a worker's capture runs with, which also keeps
%% the instance and its images out of the measuring process.
snapshot_round(G, Repeats) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} =
        spawn_opt(fun() ->
                          {ok, Inst} = reactorlib:capture_ready(G),
                          Ts = [timed_snapshot(G, Inst)
                                || _ <- lists:seq(0, Repeats)],
                          ok = wasm:destroy(Inst),
                          Parent ! {Ref, Ts}
                  end, [monitor, {min_heap_size, 2_000_000}]),
    receive
        {Ref, [F | R]} ->
            receive {'DOWN', Mon, process, Pid, _} -> ok end,
            {F, R};
        {'DOWN', Mon, process, Pid, Why} ->
            exit({snapshot_round_died, Why})
    end.

timed_snapshot(G, Inst) ->
    true = erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    {ok, S} = reactorlib:snapshot_of(G, Inst),
    T1 = erlang:monotonic_time(nanosecond),
    ok = wasm:release(S),
    (T1 - T0) / 1000.

%%% --------------------------------------------------------------- worker ---

worker_arm(Name, N, Raw) ->
    {Adapter, Opts} = reactorlib:worker_opts(Name, 120_000),
    Ts = [worker_start(Adapter, Opts) || _ <- lists:seq(1, N)],
    show(Name, "worker start", Ts),
    ok = reactorlib:write_raw(Raw, {worker_start, Name, Ts}).

worker_start(Adapter, Opts) ->
    Dir = filename:join([filename:basedir(user_cache, "erlang_wasm_bench"),
                         "capture-" ++ integer_to_list(
                                         erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(wasm, snapshot_dir, Dir),
    T0 = erlang:monotonic_time(nanosecond),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    T1 = erlang:monotonic_time(nanosecond),
    unlink(W),
    ok = wasm_script_worker:stop(W),
    {ok, Files} = file:list_dir(Dir),
    Files =/= [] orelse exit({nothing_filed, Dir}),
    ok = file:del_dir_r(Dir),
    ok = application:unset_env(wasm, snapshot_dir),
    (T1 - T0) / 1000.

show(Name, Op, Us) ->
    io:format("~-9s ~-16s ~4w  min ~12.1f us  median ~12.1f us~n",
              [Name, Op, length(Us), lists:min(Us), reactorlib:med(Us)]).
