%% @doc Replays the official WebAssembly specification test suite.
%%
%% Suites are read straight from the upstream `.wast' sources: `wasm_wast'
%% turns a script into a command list and this module interprets it against the
%% runtime. Nothing is generated and no tool is needed, so running conformance
%% is one clone away:
%%
%% ```
%% git clone --depth 1 https://github.com/WebAssembly/testsuite.git
%% '''
%%
%% `WASM_TESTSUITE' names the checkout if it is somewhere else.
%%
%% The runner is phase-aware. Until the interpreter lands there is no way to
%% answer `assert_return', so commands beyond the enabled phases are counted as
%% skipped rather than failed. That keeps the suite runnable from the first
%% milestone and makes the coverage number honest: a skip is visible, whereas
%% silently passing a test we never ran is how a runtime ends up claiming
%% conformance it does not have.
-module(wasm_spec_runner).

-export([run/2, run/3, run_source/3, run_source/4, run_all/2, run_all/3,
         suite_dir/0, suites/0, fixtures_dir/0, format_report/1]).


-type phase() :: decode | validate | execute.

-type result() :: #{suite := binary(),
                    pass := non_neg_integer(),
                    fail := non_neg_integer(),
                    skip := non_neg_integer(),
                    failures := [map()]}.

%% State threaded through one suite's command list.
-record(st, {phases :: [phase()],
             %% The `spectest' module, built once per script.
             %%
             %% It used to be built per module load, which made every importer
             %% of `spectest.memory' see a *different* memory, where the suite
             %% means them to share one. It also leaked: a shared memory is
             %% owned by the engine rather than by the process that made it, so
             %% the abandoned ones were never released and a full replay held
             %% five thousand pages of a sixteen thousand page budget.
             imports = #{} :: map(),
             inst :: term(),                     % current instance, if any
             registry = #{} :: #{binary() => term()},
             %% Modules also carry their textual `$id' from the `.wast', and
             %% actions may target a module by that id rather than by a
             %% registered alias. Tracking only the registry and the most
             %% recent instance made every such action look for an export on
             %% the wrong instance.
             named = #{} :: #{binary() => term()},
             %% Module *definitions*, which are validated modules that have not
             %% been instantiated. `(module instance $I $M)' instantiates one,
             %% and may do it more than once: that is what `instance.wast'
             %% exists to check, since instantiation is generative and two
             %% instances of one definition must share nothing.
             defs = #{} :: #{binary() => term()},
             pass = 0 :: non_neg_integer(),
             fail = 0 :: non_neg_integer(),
             skip = 0 :: non_neg_integer(),
             failures = [] :: [map()],
             max_failures :: pos_integer(),
             %% Instance options, handed to every `wasm:instantiate/3' this
             %% replay performs. Empty for the ordinary phases, which is the
             %% interpreter; the compiled phase puts the tier's options here.
             opts = #{} :: map()}).

%%% ------------------------------------------------------------------ api ---

-spec suite_dir() -> file:filename_all().
suite_dir() ->
    case os:getenv("WASM_TESTSUITE") of
        false -> search_up(filename:absname("."), 8);
        Dir -> Dir
    end.

%% Common Test, `rebar3 shell' and a plain `erl' all start in different
%% directories, so locate the checkout by walking up rather than assuming one.
%% Beside the project rather than inside `test', because rebar3 copies `test'
%% into `_build' for every run and the checkout is forty-five megabytes with a
%% `.git' of its own.
search_up(Dir, N) -> find_up(Dir, ["testsuite"], N).

find_up(_Dir, Parts, 0) -> filename:join(Parts);
find_up(Dir, Parts, N) ->
    Candidate = filename:join([Dir | Parts]),
    case filelib:is_dir(Candidate) of
        true -> Candidate;
        false ->
            case filename:dirname(Dir) of
                Dir -> filename:join(Parts);
                Parent -> find_up(Parent, Parts, N - 1)
            end
    end.

%% @doc The committed test data, which is not the specification suite: a few
%% modules a real toolchain emitted, used as benchmark and property seeds.
-spec fixtures_dir() -> file:filename_all().
fixtures_dir() -> find_up(filename:absname("."), ["test", "fixtures"], 8).

%% @doc Every suite the checkout holds, whether or not this runtime claims it.
-spec suites() -> [binary()].
suites() ->
    Files = filelib:wildcard(filename:join(suite_dir(), "*.wast")),
    Named = [list_to_binary(filename:basename(F, ".wast")) || F <- Files],
    %% The two that come from a proposal directory are not found by the
    %% wildcard, so they are named rather than silently absent.
    lists:sort(Named ++ [<<"atomic">>, <<"exports-threads">>]).

-spec run_all([binary()], [phase()]) -> [result()].
run_all(Suites, Phases) -> run_all(Suites, Phases, #{}).

%% @doc Replay every named suite, instantiating with `Opts'.
%%
%% With options, each suite runs in a process of its own, and that is load
%% bearing rather than tidiness. An instance's code-slot lease belongs to the
%% process that claimed it and is given back when that process dies; this
%% runner never destroys an instance, because a `.wast' script may name one
%% again at any later point. In one process, the seventeenth module command
%% would find every slot leased, `claim_loading/3' would answer `no_slot', and
%% the rest of the run would interpret while still reporting a full pass. A
%% process per suite hands all sixteen slots back between suites.
%%
%% Inside one suite the ceiling remains: module commands past the sixteenth
%% interpret. That costs the suites with many modules and few assertions, which
%% are mostly `assert_malformed' and never execute anyway, and costs almost
%% nothing on the ones that exercise the tier: `f32' and `f64' are three
%% modules and 2,500 assertions each, `conversions' one module and 526.
%%
%% Without options there is nothing to reclaim, so the plain path stays a list
%% comprehension in the calling process.
-spec run_all([binary()], [phase()], map()) -> [result()].
run_all(Suites, Phases, Opts) when map_size(Opts) =:= 0 ->
    [run(S, Phases, Opts) || S <- Suites];
run_all(Suites, Phases, Opts) ->
    [isolated(S, fun() -> run(S, Phases, Opts) end) || S <- Suites].

%% One replay, in a process of its own. A crash is reported as that suite's
%% result rather than taking the whole phase down with it, since a phase that
%% dies on its first bad suite hides every suite after it.
isolated(Suite, F) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() -> Self ! {Ref, F()} end),
    receive
        {Ref, R} -> demonitor(Mon, [flush]), R;
        {'DOWN', Mon, process, Pid, Why} ->
            #{suite => Suite, pass => 0, fail => 1, skip => 0,
              failures => [#{error => {replay_died, Why}}]}
    end.

%% @doc Replay one suite by name, for example `<<"i32">>'.
-spec run(binary(), [phase()]) -> result().
run(Suite, Phases) -> run(Suite, Phases, #{}).

-spec run(binary(), [phase()], map()) -> result().
run(Suite, Phases, Opts) ->
    Path = filename:join(suite_dir(), wasm_spec_manifest:source_of(Suite)),
    case file:read_file(Path) of
        {ok, Source} ->
            run_source(Suite, Source, Phases, Opts);
        {error, Reason} ->
            #{suite => Suite, pass => 0, fail => 0, skip => 0,
              failures => [#{error => {source_unreadable, Path, Reason}}]}
    end.

%% @doc Replay one suite from a `.wast' source already read.
-spec run_source(binary(), binary(), [phase()]) -> result().
run_source(Suite, Source, Phases) -> run_source(Suite, Source, Phases, #{}).

-spec run_source(binary(), binary(), [phase()], map()) -> result().
run_source(Suite, Source, Phases, Opts) ->
    case wasm_wast:script(Source) of
        {ok, Cmds} -> replay(Suite, Cmds, Phases, Opts);
        {error, Error} ->
            #{suite => Suite, pass => 0, fail => 0, skip => 0,
              failures => [#{error => {script_unreadable, Error}}]}
    end.

replay(Suite, Cmds, Phases, Opts) ->
    %% The cap keeps a broken suite from producing megabytes of output, but it
    %% also hides the tail while diagnosing, so it is settable:
    %% WASM_SPEC_MAX_FAILURES=1000 to see everything.
    Max = case os:getenv("WASM_SPEC_MAX_FAILURES") of
              false -> 25;
              V -> list_to_integer(V)
          end,
    St = lists:foldl(fun command/2,
                     #st{phases = Phases, max_failures = Max, opts = Opts,
                         imports = wasm_spectest:imports()}, Cmds),
    #{suite => Suite, pass => St#st.pass, fail => St#st.fail,
      skip => St#st.skip, failures => lists:reverse(St#st.failures)}.

%%% -------------------------------------------------------------- commands ---

%% A module command carries either compiled bytes or text. Both are modules;
%% only where they come from differs.
command(#{<<"type">> := <<"module">>} = C, St) ->
    %% Establishes the instance later assertions run against. A failure here
    %% is a real failure: the suite's own modules are valid by construction.
    case load_wasm(St, C) of
        {ok, Inst} -> bump_pass(remember(St#st{inst = Inst}, C, Inst));
        {skipped, _Why} -> bump_skip(St#st{inst = undefined});
        {error, Err} -> add_failure(St#st{inst = undefined}, C, {module_failed, Err})
    end;

command(#{<<"type">> := <<"assert_malformed">>} = C, St) ->
    expect_class(St, C, malformed);

command(#{<<"type">> := <<"assert_invalid">>} = C, St) ->
    case enabled(validate, St) of
        true -> expect_class(St, C, invalid);
        false -> bump_skip(St)
    end;

command(#{<<"type">> := <<"assert_unlinkable">>} = C, St) ->
    case enabled(execute, St) of
        true -> expect_class(St, C, link);
        false -> bump_skip(St)
    end;

%% Instantiation is expected to succeed and then trap, typically because an
%% active data or element segment is out of bounds, or the start function
%% traps. Distinct from `assert_unlinkable', which fails before any code runs.
command(#{<<"type">> := <<"assert_uninstantiable">>} = C, St) ->
    case enabled(execute, St) of
        true -> expect_class(St, C, trap);
        false -> bump_skip(St)
    end;

%% `register` may name which module to register. Without a name it registers
%% the most recently instantiated one.
command(#{<<"type">> := <<"register">>, <<"as">> := As} = C, St) ->
    Inst = case maps:get(<<"name">>, C, undefined) of
               undefined -> St#st.inst;
               Name -> maps:get(Name, St#st.named, St#st.inst)
           end,
    bump_pass(St#st{registry = maps:put(As, Inst, St#st.registry)});

%% Assertions against an instance that never loaded are skipped rather than
%% counted as failures. One unsupported module would otherwise report as
%% hundreds of independent failures and drown the signal; the module's own
%% failure is still counted once.
command(#{<<"type">> := <<"assert_return">>} = C, St) ->
    case enabled(execute, St) andalso St#st.inst =/= undefined of
        true -> assert_return(St, C);
        false -> bump_skip(St)
    end;
command(#{<<"type">> := <<"assert_trap">>} = C, St) ->
    case enabled(execute, St) andalso St#st.inst =/= undefined of
        true -> assert_failure(St, C, trap);
        false -> bump_skip(St)
    end;
command(#{<<"type">> := <<"assert_exhaustion">>} = C, St) ->
    case enabled(execute, St) andalso St#st.inst =/= undefined of
        true -> assert_failure(St, C, exhaustion);
        false -> bump_skip(St)
    end;
command(#{<<"type">> := <<"action">>} = C, St) ->
    case enabled(execute, St) of
        true ->
            case invoke(St, maps:get(<<"action">>, C)) of
                {ok, _} -> bump_pass(St);
                {error, E} -> add_failure(St, C, {action_failed, E})
            end;
        false -> bump_skip(St)
    end;

%% The action must raise a WebAssembly exception that nothing caught.
%%
%% The runtime reports that as a trap whose *kind* names it, rather than as a
%% class of its own -- see `wasm_exec:call/5', which pins the carried values
%% and then raises `uncaught_exception'. So the kind is what this asserts, and
%% asserting the class alone would pass on any trap at all.
command(#{<<"type">> := <<"assert_exception">>} = C, St) ->
    case enabled(execute, St) andalso St#st.inst =/= undefined of
        true -> assert_failure(St, C, trap, uncaught_exception);
        false -> bump_skip(St)
    end;

%% `(module definition $M ...)': validated and kept under its name, not
%% instantiated. An unnamed one can never be referred to afterwards, so it is
%% validated and then dropped rather than recorded.
command(#{<<"type">> := <<"module_definition">>} = C, St) ->
    case defined(St, C) of
        {ok, M} ->
            case maps:get(<<"name">>, C, undefined) of
                undefined -> bump_pass(St);
                Name -> bump_pass(St#st{defs = maps:put(Name, M, St#st.defs)})
            end;
        {skipped, _Why} -> bump_skip(St);
        {error, Err} -> add_failure(St, C, {module_failed, Err})
    end;

%% `(module instance $I $M)': instantiate a definition and bind the result to
%% the instance name, so `register' and later actions can target it.
command(#{<<"type">> := <<"module_instance">>, <<"instance">> := IName,
          <<"module">> := MName} = C, St) ->
    case enabled(execute, St) of
        false -> bump_skip(St);
        true -> instantiate_definition(St, C, IName, MName)
    end;

command(_Other, St) ->
    bump_skip(St).

instantiate_definition(St, C, IName, MName) ->
    case maps:find(MName, St#st.defs) of
        error ->
            add_failure(St#st{inst = undefined}, C, {unknown_definition, MName});
        {ok, M} ->
            case wasm:instantiate(M, imports_for(St, M), St#st.opts) of
                {ok, Inst} ->
                    bump_pass(St#st{inst = Inst,
                                    named = maps:put(IName, Inst, St#st.named)});
                {error, E} ->
                    add_failure(St#st{inst = undefined}, C, {module_failed, E})
            end
    end.

%%% --------------------------------------------------------------- helpers ---

enabled(Phase, #st{phases = Ps}) -> lists:member(Phase, Ps).

%% Decode, then validate if that phase is on, then instantiate if that is on.
load_wasm(St, C) ->
    case decoded(C) of
        {error, E} -> {error, E};
        {ok, M} -> load_wasm_validate(St, M)
    end.

%% Where a command's module comes from. It travels with the command, as text
%% already read, as text carried in a string, or as bytes written out directly.
decoded(#{<<"module">> := {binary, Bytes}}) ->
    wasm_decode:module(Bytes);
decoded(#{<<"module">> := {form, Form}}) ->
    wasm_wat:module_form(Form);
decoded(#{<<"module">> := {quote, Source}}) ->
    wasm_wat:module(Source).

load_wasm_validate(St, M) ->
    case enabled(validate, St) of
        false -> {skipped, validate_disabled};
        true ->
            case wasm_validate:module(M) of
                {error, E} -> {error, E};
                {ok, Validated} -> load_wasm_instantiate(St, Validated)
            end
    end.

%% Decode and validate without instantiating, for a definition that will be
%% instantiated later, more than once, or not at all.
defined(St, C) ->
    case decoded(C) of
        {error, E} -> {error, E};
        {ok, M} ->
            case enabled(validate, St) of
                false -> {skipped, validate_disabled};
                true -> wasm_validate:module(M)
            end
    end.

load_wasm_instantiate(St, M) ->
    case enabled(execute, St) of
        false -> {skipped, execute_disabled};
        true ->
            case wasm:instantiate(M, imports_for(St, M), St#st.opts) of
                {ok, Inst} -> {ok, Inst};
                {error, E} -> {error, E}
            end
    end.

%% Assert that loading `File' fails, and fails with the expected class. Class
%% matters: a module rejected as malformed when the suite says invalid means
%% the decoder is enforcing something validation owns, which usually indicates
%% the decoder will also reject a legal module somewhere else.
expect_class(St, C, Want) ->
    case classify(C, St) of
        {failed, Want, _Err} ->
            bump_pass(St);
        {failed, Other, Err} ->
            add_failure(St, C, {wrong_error_class,
                                #{wanted => Want, got => Other, error => Err}});
        accepted ->
            add_failure(St, C, {should_have_failed, Want})
    end.

%% Run a module through as much of the pipeline as the enabled phases allow,
%% and report the first stage that rejected it.
%%
%% Instantiation is part of this. Without it `assert_unlinkable` could never
%% observe a link error and every such case reported "should have failed",
%% which was the single largest source of failures in `imports` and `linking`
%% and was hiding whatever the link checking really does.
classify(C, St) ->
    maybe
        {ok, M} ?= decoded(C),
        ok ?= classify_validate(M, St),
        classify_instantiate(M, St)
    else
        {error, #{class := Class} = E} -> {failed, Class, E};
        {error, Other} -> {failed, unreadable, Other};
        {failed, _, _} = Failed -> Failed;
        accepted -> accepted
    end.

classify_validate(M, St) ->
    case enabled(validate, St) of
        false -> ok;
        true ->
            case wasm_validate:module(M) of
                {ok, _} -> ok;
                {error, #{class := Class} = E} -> {failed, Class, E}
            end
    end.

classify_instantiate(M, St) ->
    case enabled(execute, St) of
        false -> accepted;
        true ->
            case wasm:instantiate(M, imports_for(St, M), St#st.opts) of
                {ok, _} -> accepted;
                {error, #{class := Class} = E} -> {failed, Class, E}
            end
    end.

assert_return(St, C) ->
    Expected = maps:get(<<"expected">>, C, []),
    case invoke(St, maps:get(<<"action">>, C)) of
        {ok, Got} ->
            case compare_results(Expected, Got) of
                ok -> bump_pass(St);
                {mismatch, Detail} -> add_failure(St, C, {mismatch, Detail});
                %% Counted as a skip, which is what it is. Counting it as a
                %% pass is how an assertion that checks nothing hides.
                {unchecked, _Detail} -> bump_skip(St)
            end;
        {error, E} ->
            add_failure(St, C, {unexpected_error, E})
    end.

assert_failure(St, C, WantClass) ->
    case invoke(St, maps:get(<<"action">>, C)) of
        {error, #{class := WantClass}} -> bump_pass(St);
        {error, #{class := Other} = E} ->
            add_failure(St, C, {wrong_error_class,
                                #{wanted => WantClass, got => Other, error => E}});
        {ok, Got} -> add_failure(St, C, {should_have_failed, WantClass, Got})
    end.

%% As above, but the kind matters too. A separate function rather than a
%% loosening of the one above: `assert_trap' means any trap, and an assertion
%% that names a specific one has to keep saying so.
assert_failure(St, C, WantClass, WantKind) ->
    case invoke(St, maps:get(<<"action">>, C)) of
        {error, #{class := WantClass, kind := WantKind}} -> bump_pass(St);
        {error, E} ->
            add_failure(St, C, {wrong_error,
                                #{wanted => {WantClass, WantKind}, error => E}});
        {ok, Got} -> add_failure(St, C, {should_have_failed, WantKind, Got})
    end.

invoke(#st{inst = undefined}, _Action) ->
    {error, #{class => link, kind => no_instance,
              msg => <<"no current instance">>, ctx => #{}}};
%% The *named* target can be undefined too: `register' records whatever the
%% current instance is, and a module that failed to load leaves that undefined.
%% Without this the action reached `wasm:call(undefined, ...)' and killed the
%% whole run rather than counting one failure.
invoke(St, #{<<"type">> := <<"invoke">>, <<"field">> := Field} = A) ->
    Args = [decode_value(V) || V <- maps:get(<<"args">>, A, [])],
    with_target(St, A, fun(T) -> wasm:call(T, Field, Args) end);
invoke(St, #{<<"type">> := <<"get">>, <<"field">> := Field} = A) ->
    with_target(St, A, fun(T) -> wasm:get_global(T, Field) end);
invoke(_St, Other) ->
    {error, #{class => link, kind => unknown_action,
              msg => <<"unknown action">>, ctx => #{action => Other}}}.

with_target(St, A, Fun) ->
    case target_instance(St, A) of
        undefined ->
            {error, #{class => link, kind => no_instance,
                      msg => <<"no current instance">>, ctx => #{}}};
        Target -> Fun(Target)
    end.

%% Imports are resolved against the standard `spectest' module plus any
%% instance the suite has previously registered by name, which is how the
%% linking tests wire modules to each other.
imports_for(#st{registry = Reg, imports = Spectest}, M) ->
    Needed = wasm_module_imports(M),
    lists:foldl(
      fun({Mod, Name} = Key, Acc) ->
          %% An unresolvable import is left out deliberately, so that
          %% instantiation reports `unknown_import' naming it, rather than the
          %% runner silently substituting something and reporting a confusing
          %% failure further downstream.
          case maps:find(Mod, Reg) of
              {ok, Inst} when Inst =/= undefined ->
                  case wasm:extern(Inst, Name) of
                      {ok, V} -> Acc#{Key => V};
                      {error, _} -> Acc
                  end;
              _ -> Acc
          end
      end, Spectest, Needed).

wasm_module_imports(M) -> wasm_decode:imports(M).

%% An action's `module' is a `.wast' module id, which may or may not also have
%% been registered under the same name. Check both before falling back.
target_instance(St, A) ->
    case maps:get(<<"module">>, A, undefined) of
        undefined -> St#st.inst;
        Name ->
            case maps:find(Name, St#st.named) of
                {ok, Inst} -> Inst;
                error -> maps:get(Name, St#st.registry, St#st.inst)
            end
    end.

remember(St, C, Inst) ->
    case maps:get(<<"name">>, C, undefined) of
        undefined -> St;
        Name -> St#st{named = maps:put(Name, Inst, St#st.named)}
    end.

%%% ---------------------------------------------------------------- values ---

%% Integers arrive as signed decimal strings, which is exactly the signed
%% two's-complement form the runtime holds them in, so no conversion is needed.
%% Floats arrive as unsigned bit patterns, because the suite has to be able to
%% name NaN payloads and signed zero that decimal notation cannot express.
decode_value(#{<<"type">> := <<"i32">>, <<"value">> := V}) -> binary_to_integer(V);
decode_value(#{<<"type">> := <<"i64">>, <<"value">> := V}) -> binary_to_integer(V);
decode_value(#{<<"type">> := <<"f32">>, <<"value">> := V}) ->
    wasm_num:f32_from_bits(binary_to_integer(V));
decode_value(#{<<"type">> := <<"f64">>, <<"value">> := V}) ->
    wasm_num:f64_from_bits(binary_to_integer(V));
decode_value(#{<<"type">> := <<"externref">>, <<"value">> := <<"null">>}) -> null;
decode_value(#{<<"type">> := <<"externref">>, <<"value">> := V}) ->
    {externref, binary_to_integer(V)};
decode_value(#{<<"type">> := <<"funcref">>, <<"value">> := <<"null">>}) -> null;
%% Reference *arguments*, not just results. Without these a null `anyref' was
%% passed as the `{unsupported_value, _}' fallback, so the module under test
%% received a term it could make no sense of and the assertion failed for a
%% reason that had nothing to do with the runtime.
decode_value(#{<<"type">> := T, <<"value">> := <<"null">>})
  when T =:= <<"anyref">>; T =:= <<"eqref">>; T =:= <<"structref">>;
       T =:= <<"arrayref">>; T =:= <<"i31ref">>; T =:= <<"nullref">>;
       T =:= <<"nullfuncref">>; T =:= <<"nullexternref">>;
       T =:= <<"exnref">>; T =:= <<"nullexnref">> -> null;
%% `(ref.host N)': a host reference viewed from the internal hierarchy, which is
%% exactly what `any.convert_extern' produces. Externalising it has to give back
%% `(ref.extern N)', so the two must be each other's inverse here as well.
decode_value(#{<<"type">> := T, <<"value">> := V})
  when T =:= <<"anyref">>; T =:= <<"eqref">> ->
    {internal, {externref, binary_to_integer(V)}};
decode_value(#{<<"type">> := <<"i31ref">>, <<"value">> := V}) ->
    {i31, binary_to_integer(V) band 16#7FFFFFFF};
%% A `v128' arrives as a list of per-lane decimal strings plus the lane type
%% that says how wide each is. Float lanes are given as bit patterns like every
%% other float in the suite, so they need no conversion here: the lane is
%% assembled from the pattern directly.
decode_value(#{<<"type">> := <<"v128">>, <<"lane_type">> := LT,
               <<"value">> := Lanes}) ->
    Bits = lane_bits(LT),
    << <<(binary_to_integer(L)):Bits/little>> || L <- Lanes >>;
decode_value(Other) -> {unsupported_value, Other}.

lane_bits(<<"i8">>) -> 8;
lane_bits(<<"i16">>) -> 16;
lane_bits(<<"i32">>) -> 32;
lane_bits(<<"i64">>) -> 64;
lane_bits(<<"f32">>) -> 32;
lane_bits(<<"f64">>) -> 64.

compare_results(Expected, Got) when length(Expected) =/= length(Got) ->
    {mismatch, #{reason => arity, expected => length(Expected), got => length(Got)}};
compare_results(Expected, Got) ->
    compare_each(lists:zip(Expected, Got), 1).

%% An expected value the matcher does not understand stops the comparison, and
%% the assertion is reported as *unchecked* rather than counted as a pass.
%%
%% It used to answer `ok' for the whole remaining list, so one unrecognised
%% value passed itself and every value after it, and the assertion was tallied
%% as passing. That is the same shape as the defect which once had 27
%% assertions passing without checking anything: a harness that cannot compare
%% something has to say so, not shrug.
compare_each([], _N) -> ok;
compare_each([{E, G} | Rest], N) ->
    case match_value(E, G) of
        true -> compare_each(Rest, N + 1);
        false -> {mismatch, #{index => N, expected => E, got => G}};
        skip -> {unchecked, #{index => N, expected => E}}
    end.

%% Float comparison is bitwise, not numeric: the specification distinguishes
%% +0.0 from -0.0 and distinguishes NaN payloads, and `==' would conflate both.
match_value(#{<<"type">> := <<"f32">>, <<"value">> := <<"nan:canonical">>}, G) ->
    is_canonical_nan(G, 16#400000);
match_value(#{<<"type">> := <<"f64">>, <<"value">> := <<"nan:canonical">>}, G) ->
    is_canonical_nan(G, 16#8000000000000);
match_value(#{<<"type">> := _, <<"value">> := <<"nan:arithmetic">>}, G) ->
    wasm_num:is_nan(G);
match_value(#{<<"type">> := <<"f32">>, <<"value">> := V}, G) ->
    catch_bits(fun() -> wasm_num:f32_to_bits(G) end) =:= binary_to_integer(V);
match_value(#{<<"type">> := <<"f64">>, <<"value">> := V}, G) ->
    catch_bits(fun() -> wasm_num:f64_to_bits(G) end) =:= binary_to_integer(V);
match_value(#{<<"type">> := T, <<"value">> := V}, G)
  when T =:= <<"i32">>; T =:= <<"i64">> ->
    binary_to_integer(V) =:= G;
match_value(#{<<"type">> := <<"externref">>, <<"value">> := <<"null">>}, G) ->
    G =:= null;
match_value(#{<<"type">> := <<"funcref">>, <<"value">> := <<"null">>}, G) ->
    G =:= null;
%% `refnull' is the type-erased spelling of the same thing.
%% Guarded against `null', which the reference-kind clause below handles: a
%% host reference is named by number, and "null" is not one.
match_value(#{<<"type">> := T, <<"value">> := V}, G)
  when V =/= <<"null">>, T =:= <<"anyref">> orelse T =:= <<"eqref">> ->
    G =:= {internal, {externref, binary_to_integer(V)}};
%% The bottom of each hierarchy, and the type-erased `refnull'. All name the
%% null reference and carry no value of their own.
match_value(#{<<"type">> := T}, G)
  when T =:= <<"refnull">>; T =:= <<"nullref">>; T =:= <<"nullfuncref">>;
       T =:= <<"nullexternref">>; T =:= <<"nullexnref">> ->
    G =:= null;
%% A *non-null* external reference. The harness could only check the null case,
%% so every assertion naming a particular host reference was falling through to
%% the catch-all and being counted as a pass: 116 of them across the core
%% suites, in `table_fill', `table_grow', `br_table' and a dozen others.
match_value(#{<<"type">> := <<"externref">>, <<"value">> := V}, G) ->
    G =:= {externref, binary_to_integer(V)};
%% A reference of the right kind, with no particular one named.
match_value(#{<<"type">> := <<"externref">>}, G) ->
    G =/= null andalso is_extern(G);
match_value(#{<<"type">> := <<"funcref">>}, G) ->
    G =/= null andalso is_func(G);
%% Vector results are compared lane by lane rather than as whole binaries,
%% because a float lane may be specified as `nan:canonical' or `nan:arithmetic'
%% rather than as a bit pattern, and those match a set of values rather than one.
match_value(#{<<"type">> := <<"v128">>, <<"lane_type">> := LT,
              <<"value">> := Lanes}, G) when is_binary(G), byte_size(G) =:= 16 ->
    Bits = lane_bits(LT),
    Got = [X || <<X:Bits/little>> <= G],
    length(Got) =:= length(Lanes) andalso
        lists:all(fun({E, A}) -> match_lane(LT, E, A) end,
                  lists:zip(Lanes, Got));
%% A reference result named without a value asserts the *shape* of what came
%% back. These previously fell through the catch-all below and were skipped, so
%% twenty-seven assertions passed without checking anything at all.
match_value(#{<<"type">> := T} = E, G) when T =:= <<"structref">>;
                                            T =:= <<"arrayref">>;
                                            T =:= <<"anyref">>;
                                            T =:= <<"eqref">>;
                                            T =:= <<"i31ref">>;
                                            T =:= <<"nullref">>;
                                            T =:= <<"exnref">> ->
    case maps:get(<<"value">>, E, undefined) of
        <<"null">> -> G =:= null;
        undefined -> is_reference_value(T, G);
        V -> is_reference_value(T, G) andalso matches_i31(T, V, G)
    end;
match_value(#{<<"type">> := <<"either">>, <<"values">> := Vs}, G) ->
    lists:any(fun(V) -> match_value(V, G) =:= true end, Vs);
match_value(_Unsupported, _G) ->
    skip.

%% A lane's expected value is a decimal bit pattern, or one of the two NaN
%% wildcards. `nan:canonical' admits either sign, so only the payload is checked.
match_lane(<<"f32">>, <<"nan:canonical">>, A) -> nan_lane(A, 32, canonical);
match_lane(<<"f64">>, <<"nan:canonical">>, A) -> nan_lane(A, 64, canonical);
match_lane(<<"f32">>, <<"nan:arithmetic">>, A) -> nan_lane(A, 32, any);
match_lane(<<"f64">>, <<"nan:arithmetic">>, A) -> nan_lane(A, 64, any);
%% Lanes are compared as unsigned bit patterns. The suite writes them as signed
%% decimals where that is shorter, so -1 and 4294967295 are the same i32 lane.
match_lane(LT, Expected, A) ->
    Bits = lane_bits(LT),
    (binary_to_integer(Expected) band ((1 bsl Bits) - 1)) =:= A.

nan_lane(Bits, 32, Kind) -> nan_pattern(Bits, 8, 23, 16#400000, Kind);
nan_lane(Bits, 64, Kind) -> nan_pattern(Bits, 11, 52, 16#8000000000000, Kind).

nan_pattern(Bits, ExpBits, MantBits, Quiet, Kind) ->
    Mant = Bits band ((1 bsl MantBits) - 1),
    Exp = (Bits bsr MantBits) band ((1 bsl ExpBits) - 1),
    IsNan = Exp =:= (1 bsl ExpBits) - 1 andalso Mant =/= 0,
    case Kind of
        any -> IsNan;
        canonical -> IsNan andalso Mant =:= Quiet
    end.

%% `null' satisfies any nullable reference type; otherwise the value has to be
%% the right kind of thing. `anyref' and `eqref' admit several kinds, which is
%% the point of their being abstract.
is_reference_value(_T, null) -> true;
is_reference_value(<<"structref">>, {objref, _}) -> true;
is_reference_value(<<"arrayref">>, {objref, _}) -> true;
is_reference_value(<<"i31ref">>, {i31, _}) -> true;
is_reference_value(<<"nullref">>, _) -> false;
is_reference_value(T, {objref, _}) when T =:= <<"anyref">>; T =:= <<"eqref">> ->
    true;
is_reference_value(T, {i31, _}) when T =:= <<"anyref">>; T =:= <<"eqref">> ->
    true;
is_reference_value(<<"anyref">>, _) -> true;
is_reference_value(<<"exnref">>, _) -> true;
is_reference_value(_T, _G) -> false.

%% An `i31ref' may name its value, and that is the one reference kind whose
%% contents the suite can state.
matches_i31(<<"i31ref">>, V, {i31, Got}) ->
    (binary_to_integer(V) band 16#7FFFFFFF) =:= Got;
matches_i31(_T, _V, _G) -> true.

is_canonical_nan({nan, _S, Payload}, Payload) -> true;
is_canonical_nan(_, _) -> false.

%% A reference of the right kind, when the assertion names a kind but not a
%% particular reference. `{extern, V}' is the wrapped form `extern.convert_any'
%% produces; a function reference carries its defining instance when it has one.
is_extern({externref, _}) -> true;
is_extern({extern, _}) -> true;
is_extern(_) -> false.

is_func({funcref, _}) -> true;
is_func({funcref, _, _}) -> true;
is_func(_) -> false.

catch_bits(F) -> try F() catch _:_ -> no_bits end.

%%% -------------------------------------------------------------- tallying ---

bump_pass(St) -> St#st{pass = St#st.pass + 1}.
bump_skip(St) -> St#st{skip = St#st.skip + 1}.

add_failure(#st{fail = F, failures = Fs, max_failures = Max} = St, Cmd, Why) ->
    Entry = #{line => maps:get(<<"line">>, Cmd, 0),
              type => maps:get(<<"type">>, Cmd, <<>>),
              why => Why},
    Fs1 = case length(Fs) < Max of
              true -> [Entry | Fs];
              false -> Fs
          end,
    St#st{fail = F + 1, failures = Fs1}.

%%% ---------------------------------------------------------------- report ---

-spec format_report([result()]) -> iolist().
format_report(Results) ->
    Rows = [io_lib:format("  ~-28s pass ~6w  fail ~6w  skip ~6w~n",
                          [S, P, F, K])
            || #{suite := S, pass := P, fail := F, skip := K} <- Results,
               F > 0 orelse P > 0],
    {TP, TF, TK} = lists:foldl(
        fun(#{pass := P, fail := F, skip := K}, {A, B, C}) ->
            {A + P, B + F, C + K}
        end, {0, 0, 0}, Results),
    [Rows, io_lib:format("  ~-28s pass ~6w  fail ~6w  skip ~6w~n",
                         ["TOTAL", TP, TF, TK])].
