-module(wasm_wasi2_testsuite_SUITE).
-moduledoc """
The official WASI test suite through the preview1->preview2 adapter (Track 2).

`wasi_conformance_SUITE` runs the upstream cases on `wasi_preview1`. This runs the
same cases on `wasi_preview2`, adapting each into a preview2 component first (see
`wasi2_testsuite_runner`). It is the end-to-end check that real programs run
through the whole component path: the adapter's four linked cores, the graph
linker, and the preview2 host.

Per directory, and known-failing counts rather than case lists, exactly like the
preview1 suite: a fix may lower a count freely, a regression that raises one fails
the build, and lowering a count without updating the baseline fails too. The
failures are programs that reach a preview2 function this host does not implement
yet (mostly the fuller filesystem surface); each is a stub that traps only when
called, and the count shrinks as the host grows.

Skipped without a wasi-testsuite checkout or without `wasm-tools` and the adapter.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [preview2_cases, directories_present].

%% Known-failing counts per directory. The whole `wasi:filesystem` and
%% `wasi:clocks` surface is implemented (no stubs); the c directory passes in
%% full and rust to all but one case. What remains:
%%
%% The rust and c directories pass in full. The three assemblyscript failures are
%% an upstream limitation of the wasmtime preview1 adapter, not this host: adapting
%% these assemblyscript guests to a preview2 component produces a module that traps
%% on the adapter's own assertion ("assertion failed at adapter line ~2858") and
%% aborts *on wasmtime itself*, reproduced across every adapter version tried
%% (v24 through v48). The same programs pass as native preview1 on wasmtime and on
%% this runtime (`wasi_conformance_SUITE` is zero-fail), so the WASI behaviour is
%% correct; only the assemblyscript-through-adapter path is broken, and no host
%% change or adapter version fixes it. This is the ceiling for the adapter route.
%%
%% The `stale_baseline` guard forbids leaving a number too high.
baseline() ->
    #{~"assemblyscript/wasm32-wasip1" => 3,
      ~"c/wasm32-wasip1" => 0,
      ~"rust/wasm32-wasip1" => 0}.

init_per_suite(Config) ->
    case wasi_testsuite_runner:dirs() of
        [] ->
            {skip, "no wasi-testsuite checkout: git clone --depth 1 --branch "
                   "prod/testsuite-base "
                   "https://github.com/WebAssembly/wasi-testsuite.git"};
        _ ->
            case wasi2_testsuite_runner:have_tools() of
                false ->
                    {skip, "wasm-tools or the preview1 adapter is missing"};
                true ->
                    {ok, _} = application:ensure_all_started(wasm),
                    Config
            end
    end.

end_per_suite(_) -> ok.

preview2_cases(_) ->
    Results = wasi2_testsuite_runner:run_all(),
    ct:log("~s", [wasi2_testsuite_runner:format_report(Results)]),
    Regressions = [{D, F, allowed(D)}
                   || #{dir := D, fail := F} <- Results, F > allowed(D)],
    log_failures(Results, Regressions),
    ?assertEqual([], Regressions),
    stale_baseline(Results),
    %% A run that adapted and ran nothing would also report no regressions.
    ?assert(lists:sum([P || #{pass := P} <- Results]) > 0).

directories_present(_) ->
    Dirs = wasi_testsuite_runner:dirs(),
    ct:log("~p directories: ~p", [length(Dirs), [filename:basename(D) || D <- Dirs]]),
    ?assertNotEqual([], Dirs).

%%% ---------------------------------------------------------------- helpers ---

allowed(Dir) -> maps:get(Dir, baseline(), 0).

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
log_failures(Results, Regressions) ->
    Named = maps:from_list([{maps:get(dir, R), R} || R <- Results]),
    lists:foreach(
      fun({D, Got, Allowed}) ->
          #{failures := Fs} = maps:get(D, Named),
          ct:log("~s regressed (~p failures, baseline ~p):~n~p",
                 [D, Got, Allowed, Fs])
      end, Regressions).
