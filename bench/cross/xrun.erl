-module(xrun).
-moduledoc """
Every arm of the comparison, through one implementation of the protocol.

Use this to produce the table in `bench/cross/README.md`. It exists because the
table is only honest if every runtime is measured the same way: repeated
samples, five sizes, a least-squares slope, and the same checksum asserted at a
size every arm runs. Measuring our arm more carefully than the others would be
a way of winning an argument rather than of learning anything.

    erlc -o bench/cross -pa _build/default/lib/wasm/ebin \\
        bench/cross/loop_erl.erl bench/cross/xrun.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/cross \\
        -run xrun main bench/cross/loop.wasm 1000000

**Each arm gets its own size ladder, calibrated first.** One ladder for all
four cannot work: a size where this interpreter runs for a tenth of a second is
a size where V8 does a millisecond of work behind thirty of process spawn, and
the fit then reports the spawn. The first run with a shared ladder came back
with r2 of 0.11 for node, which is the fit saying so.

The three external arms are command-line launches, so spawn and compilation
land in the intercept, which the slope removes. `erlang_wasm` runs in this
process, warmed up, because an embedded library is used from an already-running
VM. Cold start is a different question and this is not it.
""".
-export([main/1]).

-define(ROUNDS, 5).         % samples per size
-define(TARGET_US, 400000). % work at the top size, so the fit sees work
-define(CAP, 2000000000).   % refuse to calibrate past this, i32 loop or not

main([Path]) -> main([Path, "1000000"]);
main([Path, NS]) ->
    jit = erlang:system_info(emu_flavor),
    {ok, _} = application:ensure_all_started(wasm),
    Common = list_to_integer(NS),

    Arms = [{"wasm3", "interpreter, C", cli("wasm3 --func bench ~s ~w")},
            {"wasmtime", "JIT", cli("wasmtime --invoke bench ~s ~w 2>/dev/null")},
            {"node (V8)", "JIT", cli("node bench/cross/loop.js ~s ~w")},
            {"erlang_wasm", "interpreter, BEAM", fun native/1}],

    io:format("load=~s  common size=~w~n", [loop_erl:load(), Common]),
    io:format("~-14s ~-20s ~12s ~9s ~12s  ~s~n",
              ["arm", "kind", "ns/iter", "r2", "top size", "checksum"]),
    Rows = [row(Name, Kind, Make(Path), Common) || {Name, Kind, Make} <- Arms],

    %% Every arm ran the common size. If they disagree they are not running the
    %% same work and none of the numbers above mean anything.
    [Agreed] = lists:usort([C || {_, C} <- Rows]),
    io:format("checksum ~w ~w~n", [Common, Agreed]),
    init:stop().

row(Name, Kind, Run, Common) ->
    {_, Checksum} = Run(Common),
    Top = calibrate(Run, Common),
    Points = [{N, element(1, Run(N))} || N <- loop_erl:sizes(Top)],
    {Slope, _Intercept, R2} = loop_erl:fit(Points),
    io:format("~-14s ~-20s ~12.2f ~9.5f ~12w  ~w~n",
              [Name, Kind, Slope * 1000, R2, Top, Checksum]),
    {Name, Checksum}.

%% Grow the top size until the arm spends TARGET_US on iterations rather than
%% on getting started. The difference between two sizes is work; the absolute
%% time is work plus startup, and for a JIT launched from a shell the second
%% term is most of it.
calibrate(Run, N) ->
    {Lo, _} = Run(N div 5),
    {Hi, _} = Run(N),
    %% The cap returns the last size that fits, never the one past it: the
    %% loop counter is an i32 and a ladder above 2^31 is not a slower runtime,
    %% it is an argument the runtime rejects.
    case Hi - Lo >= ?TARGET_US orelse N * 5 > ?CAP of
        true -> N;
        false -> calibrate(Run, N * 5)
    end.

%% An external runtime: ROUNDS launches per size, minimum taken. There is no
%% warmup to be had from outside a process, which is what the slope is for.
cli(Fmt) ->
    fun(Path) ->
        fun(N) ->
            Cmd = lists:flatten(io_lib:format(Fmt, [Path, N])),
            Rs = [timer:tc(fun() -> os:cmd(Cmd) end) || _ <- lists:seq(1, ?ROUNDS)],
            %% Same size, same answer, every launch.
            [C] = lists:usort([checksum(Out) || {_, Out} <- Rs]),
            {float(lists:min([T || {T, _} <- Rs])), C}
        end
    end.

%% The last integer the arm printed, whatever it printed around it. `wasmtime'
%% warns about `--invoke' and `wasm3' prefixes "Result:".
checksum(Out) ->
    lists:last([I || W <- string:lexemes(Out, " \n\r\t:"),
                     {I, ""} <- [string:to_integer(W)]]).

%% Our own arm, in this process, compiled and instantiated once and warmed up
%% at whatever size it is first asked for.
native(Path) ->
    {I, _Tc, _Ti} = loop_erl:runner(Path),
    Warm = ets:new(warm, [set, public]),
    fun(N) ->
        case ets:member(Warm, N) of
            true -> ok;
            false ->
                [{ok, _} = wasm:call(I, ~"bench", [N]) || _ <- lists:seq(1, 3)],
                true = ets:insert(Warm, {N})
        end,
        Rs = [timer:tc(fun() -> wasm:call(I, ~"bench", [N]) end)
              || _ <- lists:seq(1, ?ROUNDS)],
        [C] = lists:usort([R || {_, {ok, [R]}} <- Rs]),
        {float(lists:min([T || {T, _} <- Rs])), C}
    end.
