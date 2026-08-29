-module(loop_erl).
-moduledoc """
The `erlang_wasm` arm of the cross-runtime comparison.

Run this when you want a per-iteration cost you can defend. It is the same
counted loop every other arm runs, measured to the protocol in
`bench/cross/README.md`: the JIT asserted, warmup inside this process, five
sizes, repeated samples per size, and a slope fitted across the sizes so
compilation and instantiation cancel out instead of being subtracted by hand.

    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/cross \\
        -run loop_erl main bench/cross/loop.wasm 1000000

The size argument is the largest size; the five sizes are fifths of it. The
last line prints the checksum at that size, which is the value every other
runtime must also print. If they disagree the runtimes are not running the same
work and no number here means anything.
""".
-export([main/1, measure/2, runner/1, sizes/1, fit/1, load/0]).

-define(POINTS, 5).      % sizes, per the protocol: five, not two
-define(ROUNDS, 7).      % timed samples per size
-define(WARMUP, 3).      % untimed calls at the top size, in this process

main([Path]) -> main([Path, "1000000"]);
main([Path, NS]) ->
    %% A failing match, not a boolean. An interpreter-only build produces
    %% numbers that are not comparable with anything in the README, and until
    %% now nothing noticed. Crash here rather than print them.
    jit = erlang:system_info(emu_flavor),

    {ok, _} = application:ensure_all_started(wasm),
    Top = list_to_integer(NS),
    {Points, Tc, Ti} = measure(Path, Top),

    io:format("emu_flavor=~p otp=~s load=~s~n",
              [erlang:system_info(emu_flavor), otp(), load()]),
    io:format("compile_us=~p instantiate_us=~p~n", [Tc, Ti]),
    io:format("~10s ~10s ~10s ~8s  ~s~n",
              ["n", "min_us", "med_us", "spread", "checksum"]),

    [io:format("~10w ~10.1f ~10.1f ~7.1f% ~12w~n", [N, Min, Med, Spread * 100, R])
     || {N, Min, Med, Spread, R} <- Points],

    {Slope, Intercept, R2} = fit([{N, Min} || {N, Min, _, _, _} <- Points]),
    io:format("slope=~.2f ns/iter intercept=~.1f us r2=~.5f~n",
              [Slope * 1000, Intercept, R2]),

    %% Last, on its own line, so a shell driver can compare arms with `tail -1'.
    {_, _, _, _, Checksum} = lists:last(Points),
    io:format("checksum ~w ~w~n", [Top, Checksum]),
    init:stop().

-doc "The five sizes, so every arm of the comparison measures the same points.".
sizes(Top) -> [Top * K div ?POINTS || K <- lists:seq(1, ?POINTS)].

-doc """
The measurement itself, so `xrun' runs this arm exactly as `main/1' does.
Returns one point per size plus the compilation and instantiation costs, which
belong to the intercept and not to any iteration.
""".
measure(Path, Top) ->
    {I, Tc, Ti} = runner(Path),
    [{ok, _} = wasm:call(I, ~"bench", [Top]) || _ <- lists:seq(1, ?WARMUP)],
    Points = [point(I, N) || N <- sizes(Top)],
    ok = wasm:destroy(I),
    {Points, Tc, Ti}.

-doc """
A compiled, instantiated module `xrun' can call at whatever sizes its
calibration picks, without paying compilation again for each of them.
""".
runner(Path) ->
    {ok, Bin} = file:read_file(Path),
    {Tc, {ok, M}} = timer:tc(fun() -> wasm:compile(Bin) end),
    {Ti, {ok, I}} = timer:tc(fun() -> wasm:instantiate(M, #{}) end),
    {I, Tc, Ti}.

%% One size: ROUNDS timed calls, reported as minimum, median and spread.
%% The minimum is the cleanest sample; the spread says whether to believe it.
point(I, N) ->
    Rs = [timer:tc(fun() -> wasm:call(I, ~"bench", [N]) end) || _ <- lists:seq(1, ?ROUNDS)],
    Checksums = lists:usort([R || {_, {ok, [R]}} <- Rs]),
    %% Same input, same answer, every round. If not, stop.
    [Checksum] = Checksums,
    Ts = lists:sort([T || {T, _} <- Rs]),
    Min = hd(Ts),
    Max = lists:last(Ts),
    Med = lists:nth(length(Ts) div 2 + 1, Ts),
    {N, float(Min), float(Med), (Max - Min) / Min, Checksum}.

%% Least squares through the (size, minimum) points. The slope is the
%% per-iteration cost with compilation, instantiation and call overhead in the
%% intercept where they belong; r2 says whether a straight line was the right
%% model, which it is not if the box was busy during the run.
fit(Points) ->
    N = length(Points),
    Sx = lists:sum([X || {X, _} <- Points]),
    Sy = lists:sum([Y || {_, Y} <- Points]),
    Sxy = lists:sum([X * Y || {X, Y} <- Points]),
    Sxx = lists:sum([X * X || {X, _} <- Points]),
    Slope = (N * Sxy - Sx * Sy) / (N * Sxx - Sx * Sx),
    Intercept = (Sy - Slope * Sx) / N,
    Mean = Sy / N,
    SsTot = lists:sum([(Y - Mean) * (Y - Mean) || {_, Y} <- Points]),
    SsRes = lists:sum([begin E = Y - (Slope * X + Intercept), E * E end || {X, Y} <- Points]),
    {Slope, Intercept, case SsTot of +0.0 -> 1.0; _ -> 1.0 - SsRes / SsTot end}.

otp() -> erlang:system_info(otp_release).

%% The README says the box matters more than most differences worth arguing
%% about, so record what the box was doing rather than leave it to memory.
load() ->
    case string:find(os:cmd("uptime"), "average") of
        nomatch -> "?";
        S -> string:trim(lists:last(string:split(S, ":", leading)))
    end.
