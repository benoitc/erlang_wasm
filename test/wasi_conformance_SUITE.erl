%% @doc The official WASI test suite, as a regression gate.
%%
%% The other `wasi_*' suites here are this project's own reading of Preview 1.
%% They are careful and they are still one reading. This one is somebody else's,
%% and it is the only thing in the tree that can tell us a capability is
%% implemented to the letter rather than to our understanding of the letter.
%%
%% Skipped entirely without a checkout, the same way `wasm_spec_SUITE' is:
%%
%% ```
%% git clone --depth 1 --branch prod/testsuite-base \
%%     https://github.com/WebAssembly/wasi-testsuite.git
%% '''
%%
%% Per directory rather than one total, so a fix in the filesystem cases cannot
%% mask a regression in the clock ones. Failures may go down freely; going up
%% fails the build, and so does going down without updating the baseline, since
%% a ceiling nobody tightens stops catching anything.
-module(wasi_conformance_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [preview1_cases, directories_present].

%% Known-failing counts per directory, per backend.
%%
%% **Native: none.** All 72 upstream cases pass. It was 29 when this suite was
%% written, in three groups: refused on purpose, not implemented, and real
%% differences. All three are gone.
%%
%% **Fallback: four**, and every one is something Erlang does not expose rather
%% than something this project has not done. The backend resolves a path's
%% parent and then acts on the last component by name, so it can name a symlink
%% without following it; what it cannot do is:
%%
%% - `fd_filestat_set' and `path_filestat' set a timestamp to nanosecond
%%   precision and read it back. `file:write_file_info/3' takes whole seconds.
%% - `symlink_filestat' sets a *symlink's own* times. `write_file_info/3'
%%   follows, and there is no `lutimes'.
%% - `path_link' hard-links a dangling symlink. `file:make_link/2' is `link()',
%%   which follows on darwin; `linkat' would not, and Erlang does not have it.
%%   This one is platform-dependent and would likely pass on Linux.
%%
%% All four are what the NIF is for, and the native backend passes all four.
%%
%% The rule for an entry has not changed: it must name the capability it is
%% about and must have been checked to fail because of that and not because of a
%% defect. `stale_baseline/1' fails the build when a number here is larger than
%% what happens, so this cannot quietly stop matching.
baseline() ->
    case wasi_fs:backend() of
        native -> #{};
        fallback -> #{~"rust/wasm32-wasip1" => 4}
    end.

init_per_suite(Config) ->
    case wasi_testsuite_runner:dirs() of
        [] ->
            {skip, "no wasi-testsuite checkout: git clone --depth 1 --branch "
                   "prod/testsuite-base "
                   "https://github.com/WebAssembly/wasi-testsuite.git"};
        _ ->
            {ok, _} = application:ensure_all_started(wasm),
            Config
    end.

end_per_suite(_) -> ok.

preview1_cases(_) ->
    Results = wasi_testsuite_runner:run_all(),
    ct:log("~s", [wasi_testsuite_runner:format_report(Results)]),
    Regressions = [{D, F, allowed(D)}
                   || #{dir := D, fail := F} <- Results, F > allowed(D)],
    log_failures(Results, Regressions),
    ?assertEqual([], Regressions),
    stale_baseline(Results),
    %% A run that executed nothing would report no failures. Being able to find
    %% the checkout is not the same as being able to read it.
    ?assert(lists:sum([P || #{pass := P} <- Results]) > 0).

%% The checkout must actually hold cases. An empty directory means the clone
%% took the wrong branch, which otherwise looks exactly like a clean run.
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
        _ -> ct:fail({baseline_too_generous, Stale})
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
