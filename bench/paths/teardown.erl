-module(teardown).
-moduledoc """
What it costs to take down a process that was carrying an image.

`workerbench`'s `phases` mode records a `reply` interval -- the runner's relay
and exit, the guardian's shutdown and the await reply -- of 870 us on CPython
against 37 us on QuickJS, for the same kernel doing the same thing. The image
is the candidate, because `do_submit/3` puts it in the guardian's spawn closure
and the guardian puts it in the runner's, so two processes holding one are torn
down inside that interval.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin \\
         -pa _build/test/lib/wasm/examples bench/paths/teardown.erl
    erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \\
        -pa bench/paths -run teardown main py_reactor <image.img>

**Carrying one in is not the same measurement as tearing one down**, which is
why this exists as well as the spawn-copy figure in `PERF.md`. The window here
opens when the process is already up and holding the term, and closes on its
`DOWN`: the copy is outside it on purpose.

The term is held in the process dictionary rather than in a variable the
receive returns to, so nothing the compiler does can drop it before the exit.
Each arm is paired against a `handle` arm, the same process carrying a small
term instead, so what is reported is the image's own share and not the cost of
spawning and reaping a process.
""".

-export([main/1]).

-define(ROUNDS, 200).

main([Adapter, Img]) ->
    {ok, _} = application:ensure_all_started(wasm),
    io:format("# load average: ~s", [os:cmd("uptime")]),
    {Mod, Guest} = arm(Adapter),
    {ok, Artifact} = Mod:artifact(Guest),
    #{module := H} = Mod:snapshot_capability(Artifact),
    {ok, S} = wasm:load_snapshot(Img, H),
    Parts = wasm_snapshot:to_parts(S),
    io:format("# ~s: ~w words, ~w run binaries, ~w table entries~n",
              [Adapter, erts_debug:size(S),
               lists:sum([length(maps:get(runs, M)) || M <- maps:get(mems, Parts)]),
               lists:sum([length(T) || T <- maps:get(tables, Parts)])]),
    %% Alternating, so neither arm is always the one that meets a cold
    %% scheduler, and both are read under whatever the box is doing.
    Pages = lists:sum([maps:get(pages, M) || M <- maps:get(mems, Parts)]),
    Floor = floor_of(Adapter),
    Arms = [{"carrying a handle", handle},
            {"carrying the image", S},
            {"holding the memory", {mem, Pages}},
            {"having used the floor", {heap, Floor}}],
    Rows = [{What, round_robin(Term, ?ROUNDS)} || {What, Term} <- Arms],
    [show(What, Us) || {What, Us} <- Rows],
    {_, Base} = hd(Rows),
    io:format("~n  against a bare teardown, per arm:~n"),
    [io:format("    ~-24s ~6w us (min)  ~6w us (median)~n",
               [What, lists:min(Us) - lists:min(Base), med(Us) - med(Base)])
     || {What, Us} <- tl(Rows)],
    init:stop().

%% Each arm interleaved with a bare one and read against it, rather than four
%% arms one after another: the box is never quiet and an arm that ran last
%% would be reported as whatever it was doing.
round_robin(Term, N) -> [one(Term) || _ <- lists:seq(1, N)].

%% The floors `workerbench' gives these guests, and what matters is that the
%% heap is **used**: an untouched `min_heap_size' costs nothing to spawn or to
%% reap, which is already measured. This allocates across it first.
floor_of("py_reactor") -> 1_000_000;
floor_of(_)            -> 200_000.

%% Spawn, wait until it is up and holding the term, *then* start the clock and
%% tell it to go. What is timed is the exit and the `DOWN', and nothing else.
one(Term) ->
    Parent = self(),
    {P, M} = spawn_opt(fun() ->
                           put(held, hold(Term)),
                           Parent ! {up, self()},
                           receive go -> ok end
                       end,
                       [monitor | opts(Term)]),
    receive {up, P} -> ok end,
    T0 = erlang:monotonic_time(microsecond),
    P ! go,
    receive {'DOWN', M, process, P, _} -> ok end,
    erlang:monotonic_time(microsecond) - T0.

%% What each arm actually holds when the clock starts.
hold({mem, Pages}) ->
    {ok, Mem} = wasm_memory:new(Pages, Pages),
    Mem;
hold({heap, Words}) ->
    %% Touched, not merely reserved: a list this long is written across the
    %% floor the `spawn_opt' below asked for.
    lists:seq(1, Words div 2);
hold(Term) ->
    Term.

opts({heap, Words}) -> [{min_heap_size, Words}];
opts(_)             -> [].

show(What, Us) ->
    io:format("  ~-22s min ~6w us   median ~6w us~n",
              [What, lists:min(Us), med(Us)]).

arm("py_reactor") ->
    {py_reactor_adapter,
     #{path => "test/fixtures/lang/py_reactor.wasm",
       lib => "test/fixtures/lang/py_reactor_lib"}};
arm("qjs_reactor") ->
    {qjs_reactor_adapter, #{path => "test/fixtures/lang/qjs_reactor.wasm"}}.

med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).
