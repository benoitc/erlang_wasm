-module(ssaprofile).
-moduledoc """
Where the OTP compiler spends its time on the compiled tier's generated code.

Use this before changing the generator to make cold compilation cheaper. It
captures the Core Erlang the background compiler hands to `compile:forms/2`
for QuickJS's hot set once, so every later step compiles exactly the same
input, then breaks that compile down by pass, by `beam_ssa_opt` sub-pass, by
compiler function and by generated function.

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/ssaprofile.erl
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run ssaprofile main capture /tmp/qjs.core
    erl -noshell -pa bench/paths -run ssaprofile main passes /tmp/qjs.core
    erl -noshell -pa bench/paths -run ssaprofile main tprof /tmp/qjs.core
    erl -noshell -pa bench/paths -run ssaprofile main perfun /tmp/qjs.core OUT
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run ssaprofile main brtable

`ERL_LIBS` is there because starting `wasm` needs its dependencies on the code
path. The compile steps need only OTP. `capture` runs the same QuickJS script
as `realbench qjs on` and saves the first `compile:forms/2` input of the
background compiler. `passes` compiles it
with the documented `time` option, which also times `beam_ssa_opt`'s
sub-passes. `tprof` ranks the compiler's own functions by time inside one
compile. `perfun` compiles each generated function alone, with every other
function of the unit replaced by a stub, and writes one term per function.
`brtable` measures what share of the generated Core the `br_table` arms are.

Every mode runs the compile with the same options the tier uses for `full`
quality (`wasm_core`'s `copts/1`).
""".
-export([main/1]).

-define(COPTS, [from_core, binary, return_errors]).

main(["capture", Out]) -> report(capture(Out));
main(["passes", In]) -> report(passes(load(In)));
main(["tprof", In]) -> report(tprof(load(In)));
main(["perfun", In, Out]) -> report(perfun(load(In), Out));
main(["shape", In]) -> report(shape(load(In)));
main(["subpass", In]) -> report(subpass(load(In)));
main(["brtable"]) -> report(brtable()).

%% A step that could not measure exits non-zero, so a script driving it stops
%% rather than reading an error as a result.
report(R) ->
    io:format("~p~n", [R]),
    io:format("# load ~s~n", [os:cmd("uptime")]),
    erlang:halt(case R of {error, _} -> 1; _ -> 0 end).

load(In) ->
    {ok, B} = file:read_file(In),
    binary_to_term(B).

%%% ------------------------------------------------------------- capture ---

%% The background compiler's input, taken from the call itself rather than
%% rebuilt here, so nothing about how the unit is put together can differ.
capture(Out) ->
    {ok, _} = application:ensure_all_started(wasm),
    Self = self(),
    Tracer = spawn(fun() -> wait_forms(Self) end),
    {module, compile} = code:ensure_loaded(compile),
    1 = erlang:trace_pattern({compile, forms, 2}, true, [global]),
    _ = erlang:trace(all, true, [call, {tracer, Tracer}]),
    {M, Cfg} = qjs(),
    Opts = #{compile => true, compile_after => 1},
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg), Opts),
    {ok, _} = wasm:call(I, ~"_start", []),
    %% As `realbench' does: the second instance is the one that waits on the
    %% compile. What ran is read from the first, the only one that has run.
    {ok, _J} = wasm:instantiate(M, wasi_preview1:imports(Cfg), Opts),
    receive
        {core, Core} ->
            ok = file:write_file(Out, term_to_binary(Core)),
            #{out => Out, core_nodes => cerl_trees:size(Core),
              functions => length(cerl:module_defs(Core)),
              executed => length(wasm_instance:executed(I))}
    after 600000 -> {error, no_compile_seen}
    end.

wait_forms(Owner) ->
    receive
        {trace, _, call, {compile, forms, [Core | _]}} -> Owner ! {core, Core};
        _ -> wait_forms(Owner)
    end.

qjs() ->
    {ok, B} = file:read_file("test/fixtures/lang/qjs.wasm"),
    {ok, M} = wasm:compile(B),
    Dir = filename:join(["/tmp", "wasm-realbench"]),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "bench.js"),
                         <<"var a=0; for (var i=0;i<30000;i++) "
                           "{ a=(a+i*3)^(a>>>7); } print(a);">>),
    {M, #{args => [~"qjs", ~"/s/bench.js"], env => #{},
          dirs => [{~"/s", Dir, read}],
          clocks => [monotonic, realtime], random => strong,
          stdout => fun(_) -> ok end, stderr => fun(_) -> ok end}}.

%%% -------------------------------------------------------------- passes ---

%% `time' prints every pass and, through `compile:run_sub_passes/2', every
%% `beam_ssa_opt' sub-pass, to standard output as it goes.
passes(Core) ->
    {Us, {ok, _, _}} = timer:tc(compile, forms,
                                [Core, [time | ?COPTS]]),
    #{total_ms => Us div 1000}.

%%% --------------------------------------------------------------- tprof ---

%% Time per compiler function as `call_time' records it, inside one compile,
%% in the calling process so the trace sees it. Only the SSA modules are
%% traced, so time in anything they call outside them is counted to the
%% traced caller.
tprof(Core) ->
    Mods = [beam_ssa_opt, beam_ssa_type, beam_ssa, beam_types,
            beam_ssa_dead, beam_ssa_alias, beam_ssa_ss],
    [{module, _} = code:ensure_loaded(Mod) || Mod <- Mods],
    {{ok, _, _}, Raw} =
        tprof:profile(fun() -> compile:forms(Core, [no_spawn_compiler_process
                                                    | ?COPTS]) end,
                      #{type => call_time,
                        pattern => [{Mod, '_', '_'} || Mod <- Mods],
                        report => return}),
    #{all := {call_time, Total, Lines}} =
        tprof:inspect(Raw, total, {measurement, descending}),
    #{total_us => Total,
      top => [{M, F, Calls, T, Pct}
              || {M, F, Calls, T, _PerCall, Pct}
                     <- lists:sublist(Lines, 40)]}.

%%% --------------------------------------------------------------- shape ---

%% What the compiler ends up with: generated functions become many more BEAM
%% functions once `letrec' continuations are lifted, and each lifted one takes
%% what it closes over as arguments.
shape(Core) ->
    {ok, _, Bin} = compile:forms(Core, [no_spawn_compiler_process | ?COPTS]),
    {beam_file, _, _, _, _, Code} = beam_disasm:file(Bin),
    Arities = [A || {function, _, A, _, _} <- Code],
    Sizes = [length(Is) || {function, _, _, _, Is} <- Code],
    S = lists:sort(Arities),
    N = length(S),
    #{beam_functions => N, beam_bytes => byte_size(Bin),
      arity_sum => lists:sum(S), arity_median => lists:nth(max(1, N div 2), S),
      arity_p90 => lists:nth(max(1, (N * 9) div 10), S),
      arity_max => lists:last(S), instructions => lists:sum(Sizes)}.

%%% -------------------------------------------------------------- perfun ---

%% Each function alone. The others keep their names and arities, so every
%% local call still resolves, but their bodies are a read of the process
%% dictionary, which costs the compiler next to nothing and answers a value of
%% unknown type. A stub that cannot return, such as `match_fail', would let
%% the type pass delete everything after each call and make the function look
%% far cheaper than it is.
perfun(Core, Out) ->
    Defs = cerl:module_defs(Core),
    Rows = [perfun_one(Core, Defs, N) || N <- lists:seq(1, length(Defs))],
    ok = file:write_file(Out, [io_lib:format("~p.~n", [R]) || R <- Rows]),
    Sorted = lists:reverse(lists:keysort(3, Rows)),
    Total = lists:sum([Us || {_, _, Us, _} <- Rows]),
    #{functions => length(Rows), total_ms => Total div 1000,
      top => lists:sublist(Sorted, 15)}.

perfun_one(Core, Defs, N) ->
    {Name, Fun} = lists:nth(N, Defs),
    Mod = alone(Core, Defs, N),
    garbage_collect(),
    {Us, {ok, _, Bin}} = timer:tc(compile, forms,
                                  [Mod, [no_spawn_compiler_process | ?COPTS]]),
    F = {cerl:fname_id(Name), cerl:fname_arity(Name)},
    {ok, {_, [{exports, Exp}]}} = beam_lib:chunks(Bin, [exports]),
    true = lists:member(F, Exp) orelse erlang:error({compiled_away, F}),
    {element(1, F), element(2, F), Us, cerl_trees:size(Fun)}.

%% The same compiles with `time', every pass and sub-pass summed over the
%% functions. Set beside `passes' on the whole unit, it says which passes cost
%% more when the functions are compiled together than apart.
subpass(Core) ->
    Defs = cerl:module_defs(Core),
    Sums = lists:foldl(
             fun(N, Acc) ->
                     Mod = alone(Core, Defs, N),
                     Text = captured(fun() ->
                                {ok, _, _} = compile:forms(
                                               Mod, [time, no_spawn_compiler_process
                                                     | ?COPTS])
                             end),
                     lists:foldl(fun({K, V}, A) ->
                                         maps:update_with(K, fun(X) -> X + V end,
                                                          V, A)
                                 end, Acc, timings(Text))
             end, #{}, lists:seq(1, length(Defs))),
    lists:reverse(lists:keysort(2, maps:to_list(Sums))).

%% The function under test is exported as well: with its callers stubbed
%% nothing reaches it, and the compiler would delete an unused local function
%% before any SSA pass saw it.
alone(Core, Defs, N) ->
    {Name, _} = lists:nth(N, Defs),
    Defs1 = [case I =:= N of
                 true -> D;
                 false -> stub(D)
             end || {I, D} <- lists:enumerate(Defs)],
    Exports = lists:usort([Name | cerl:module_exports(Core)]),
    cerl:update_c_module(Core, cerl:module_name(Core), Exports,
                         cerl:module_attrs(Core), Defs1).

%% `time' prints through the group leader, so a group leader of our own
%% collects it.
captured(F) ->
    Old = group_leader(),
    GL = spawn(fun() -> collect([]) end),
    group_leader(GL, self()),
    try F() after group_leader(Old, self()) end,
    GL ! {done, self()},
    receive {text, T} -> T end.

collect(Acc) ->
    receive
        {io_request, From, Reply, Req} ->
            From ! {io_reply, Reply, ok},
            collect([chars(Req) | Acc]);
        {done, P} -> P ! {text, unicode:characters_to_list(lists:reverse(Acc))}
    end.

chars({put_chars, _Enc, Chars}) -> Chars;
chars({put_chars, _Enc, M, F, A}) -> apply(M, F, A);
chars({put_chars, Chars}) -> Chars;
chars({put_chars, M, F, A}) -> apply(M, F, A);
chars(_) -> [].

%% Lines of the form `  name   :   1.234 s ...'.
timings(Text) ->
    [{string:trim(K), F}
     || Line <- string:split(Text, "\n", all),
        [K, Rest] <- [string:split(Line, ":")],
        [V | _] <- [string:split(string:trim(Rest), " s")],
        F <- [seconds(string:trim(V))], is_float(F)].

seconds(V) ->
    try list_to_float(V) catch error:badarg -> none end.

stub({Name, Fun}) ->
    Vars = [cerl:c_var(I) || I <- lists:seq(1, cerl:fun_arity(Fun))],
    {Name, cerl:c_fun(Vars, cerl:c_call(cerl:c_atom(erlang), cerl:c_atom(get),
                                        [cerl:c_atom(stub)]))}.

%%% ------------------------------------------------------------- brtable ---

%% The Core each `br_table' lowers to, taken from the generator's own return
%% value, against the whole unit the background compiler hands to
%% `compile:forms/2'. An arm's body is only the jump to its target, because
%% `instr/4' drops what follows a branch, so no table holds another and
%% nothing is counted twice.
brtable() ->
    {ok, _} = application:ensure_all_started(wasm),
    Self = self(),
    Tracer = spawn(fun() -> tally(Self, []) end),
    {module, wasm_core} = code:ensure_loaded(wasm_core),
    1 = erlang:trace_pattern({wasm_core, instr, 4},
                             [{[{br_table, '_', '_'}, '_', '_', '_'], [],
                               [{return_trace}]}], [local]),
    {module, compile} = code:ensure_loaded(compile),
    1 = erlang:trace_pattern({compile, forms, 2}, true, [global]),
    _ = erlang:trace(all, true, [call, {tracer, Tracer}]),
    {M, Cfg} = qjs(),
    Opts = #{compile => true, compile_after => 1},
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg), Opts),
    {ok, _} = wasm:call(I, ~"_start", []),
    {ok, _J} = wasm:instantiate(M, wasi_preview1:imports(Cfg), Opts),
    {Core, Tables} = receive {done, C, Ts} -> {C, Ts}
                     after 600000 -> erlang:error(no_compile_seen)
                     end,
    Whole = cerl_trees:size(Core),
    Arms = lists:sum([A || {A, _, _, _} <- Tables]),
    Defaults = lists:sum([D || {_, D, _, _} <- Tables]),
    #{tables => length(Tables), functions => length(cerl:module_defs(Core)),
      explicit_arms => lists:sum([N || {_, _, N, _} <- Tables]),
      default_arms => lists:sum([N || {_, _, _, N} <- Tables]),
      core_nodes => Whole, arm_nodes => Arms, default_arm_nodes => Defaults,
      arm_share_pct => 100 * Arms / Whole,
      default_share_pct => 100 * Defaults / Whole}.

%% Generation finishes before the compile starts, so by the time
%% `compile:forms/2' is called every table has been reported.
tally(Owner, Acc) ->
    receive
        {trace, _, return_from, {wasm_core, instr, 4}, Case} ->
            tally(Owner, [arms(Case) | Acc]);
        {trace, _, call, {compile, forms, [Core | _]}} ->
            Owner ! {done, Core, Acc};
        _ -> tally(Owner, Acc)
    end.

%% The explicit arms are every clause but the last, which is the catch-all.
%% An arm goes to the default when its body is the catch-all's body.
arms(Case) ->
    Clauses = cerl:case_clauses(Case),
    {Explicit, [Catch]} = lists:split(length(Clauses) - 1, Clauses),
    Default = strip(cerl:clause_body(Catch)),
    ToDefault = [C || C <- Explicit, strip(cerl:clause_body(C)) =:= Default],
    {lists:sum([cerl_trees:size(C) || C <- Explicit]),
     lists:sum([cerl_trees:size(C) || C <- ToDefault]),
     length(Explicit), length(ToDefault)}.

strip(T) -> cerl_trees:map(fun(N) -> cerl:set_ann(N, []) end, T).
