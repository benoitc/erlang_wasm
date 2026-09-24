-module(wasm_wasi2_p2_SUITE).
-moduledoc """
wasmtime's native `p2_*` test programs run against `wasi_preview2` (interop
track 3).

`wasi2_testsuite_SUITE` runs the official suite through the preview1->preview2
adapter. This runs wasmtime's own WASI 0.2 test programs directly, with no adapter:
each is a self-asserting command component that exits 0 on success and traps or
exits non-zero on any failure. It measures how much of each interface a real,
toolchain-built component actually exercises against this host.

Per interface group, and known-failing counts rather than case lists, exactly like
the adapter suite: a fix may lower a count freely, a regression that raises one
fails the build, and lowering a count without updating the baseline fails too. The
failures are programs that reach a WASI 0.2 method this host does not implement yet
(the socket state machine, non-blocking receive, per-descriptor rights); each is a
value carrying its trap, and the count shrinks as the host grows.

Skipped without the built fixtures: run `scripts/build-wasmtime-p2.sh` (clones the
pinned wasmtime and builds the `p2_*` command components into
`test/fixtures/wasmtime-p2`, which is not vendored).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [p2_cases, groups_present].

%% Known-failing counts per interface group. Filled from the first run; a fix
%% lowers a number, a regression raises the actual above it and fails, and a
%% number left too high (the `stale_baseline` guard) also fails.
baseline() ->
    #{~"cli"        => 7,
      ~"clocks"     => 0,
      ~"filesystem" => 1,
      ~"io"         => 2,
      ~"http"       => 11,
      ~"random"     => 0,
      ~"sockets"    => 12}.

init_per_suite(Config) ->
    case wasi_p2_runner:have_fixtures() of
        false ->
            {skip, "no wasmtime p2 fixtures: run scripts/build-wasmtime-p2.sh"};
        true ->
            {ok, _} = application:ensure_all_started(wasm),
            Config
    end.

end_per_suite(_Config) -> ok.

%% A count above baseline is a regression and fails; a count below baseline means
%% a fix landed without lowering the number, which also fails.
p2_cases(_) ->
    Results = wasi_p2_runner:run_all(),
    ct:log("~s", [wasi_p2_runner:format_report(Results)]),
    Regressions = [{D, F, allowed(D)}
                   || #{dir := D, fail := F} <- Results, F > allowed(D)],
    log_failures(Results, Regressions),
    ?assertEqual([], Regressions),
    stale_baseline(Results),
    %% A run that discovered and ran nothing would also report no regressions.
    ?assert(lists:sum([P || #{pass := P} <- Results]) > 0).

groups_present(_) ->
    ?assert(wasi_p2_runner:programs() =/= []).

allowed(Group) -> maps:get(Group, baseline(), 0).

stale_baseline(Results) ->
    Actual = maps:from_list([{D, F} || #{dir := D, fail := F} <- Results]),
    Stale = [{D, Allowed, maps:get(D, Actual, 0)}
             || {D, Allowed} <- maps:to_list(baseline()),
                maps:get(D, Actual, 0) < Allowed],
    case Stale of
        [] -> ok;
        _  -> ct:fail({baseline_too_generous, Stale})
    end.

log_failures(_Results, []) -> ok;
log_failures(Results, _Regressions) ->
    [ct:log("~ts failures:~n~p", [D, Fs])
     || #{dir := D, failures := Fs} <- Results, Fs =/= []].
