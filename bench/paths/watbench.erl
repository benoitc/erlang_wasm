-module(watbench).
-moduledoc """
What parsing WebAssembly text costs: on the specification's own modules, and
on a module of many type declarations.

Use this for a change to `wasm_wat`. Fetch the specification suites first
(`make suites`), which puts them in `testsuite/`:

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/watbench.erl
    rebar3 as test compile
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -pa _build/test/lib/wasm/test -run watbench main corpus 5
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -pa _build/test/lib/wasm/test -run watbench main digest
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run watbench main scale 8000

The inputs are every `(module ...)` written as text in the `.wast` files,
sliced out by counting parentheses, and, when `wasm_wat_SUITE` is on the code
path, the sources of its own cases (`sources/0`). The three files the suite
leaves out are left out here too.

`corpus ROUNDS` parses all of them with `wasm_wat:module/1` once per round in
a fresh process and prints the lowest total in microseconds, with the
5-minute load average at both ends. `digest` parses each once and prints how
many parsed, how many did not, and a SHA-256 over every result in order, so
two revisions can be checked to answer the same modules. `scale N` parses a
module of `N` explicit type declarations in a fresh process and prints its
reductions per type.
""".
-export([main/1]).

-define(EXCLUDED, ["id.wast", "annotations.wast", "names.wast"]).

main(["corpus", Rounds]) ->
    L0 = load(),
    Mods = corpus(),
    Us = [one_round(Mods) || _ <- lists:seq(1, list_to_integer(Rounds))],
    report(#{modules => length(Mods), corpus_us => lists:min(Us),
             load_start => L0});
main(["digest"]) ->
    Mods = corpus(),
    Rs = [wasm_wat:module(M) || M <- Mods],
    Ok = length([x || {ok, _} <- Rs]),
    report(#{inputs => length(Mods), parsed => Ok,
             refused => length(Mods) - Ok,
             sha256 => binary:encode_hex(
                         crypto:hash(sha256, term_to_binary(Rs)))});
main(["scale", N0]) ->
    N = list_to_integer(N0),
    Src = iolist_to_binary(
            ["(module ",
             [["(type (func (param i32) (result ",
               lists:nth(I rem 4 + 1, ["i32", "i64", "f32", "f64"]), ")))"]
              || I <- lists:seq(1, N)],
             ")"]),
    Self = self(),
    spawn(fun() ->
                  R0 = reds(),
                  {ok, _} = wasm_wat:module(Src),
                  Self ! {reds, reds() - R0}
          end),
    R = receive {reds, X} -> X end,
    report(#{types => N, reductions => R, per_type => R / N}).

report(R) ->
    io:format("~p.~n", [R#{load_end => load()}]),
    erlang:halt(0).

%% The 5-minute load average: `sysctl' prints `{ 1min 5min 15min }'.
load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).

reds() -> element(2, process_info(self(), reductions)).

one_round(Mods) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        T0 = erlang:monotonic_time(),
        _ = [wasm_wat:module(M) || M <- Mods],
        T1 = erlang:monotonic_time(),
        Self ! {self(), T1 - T0}
    end),
    receive
        {Pid, T} ->
            demonitor(Ref, [flush]),
            erlang:convert_time_unit(T, native, microsecond);
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({round_died, Why})
    end.

%% Every top-level `(module ...)' written as text, sliced out by counting
%% parentheses, as `wasm_wat_SUITE' does: the binary, quoted, definition and
%% instance forms are script commands, not text modules.
corpus() ->
    Files = [F || F <- filelib:wildcard("testsuite/*.wast"),
                  not lists:member(filename:basename(F), ?EXCLUDED)],
    [] =/= Files orelse erlang:error(no_testsuite),
    lists:append([modules_in(F) || F <- Files]) ++ suite_sources().

%% The inputs of `wasm_wat_SUITE', when its compiled module is on the path.
suite_sources() ->
    case code:ensure_loaded(wasm_wat_SUITE) of
        {module, _} -> wasm_wat_SUITE:sources();
        {error, _} -> []
    end.

modules_in(Path) ->
    {ok, Bin} = file:read_file(Path),
    Spans = spans(wasm_wat_lex:scan_all(Bin), 0, undefined, []),
    [Text || {Start, End} <- Spans,
             Text <- [binary:part(Bin, Start, End - Start)],
             is_module_text(Text)].

is_module_text(<<"(module", C, Rest/binary>>)
  when C =:= $\s; C =:= $\n; C =:= $\t; C =:= $\r; C =:= $) ->
    nomatch =:= binary:match(binary:part(Rest, 0, min(24, byte_size(Rest))),
                             [<<"binary">>, <<"quote">>, <<"definition">>,
                              <<"instance">>]);
is_module_text(_Text) ->
    false.

spans([], _Depth, _Start, Acc) ->
    lists:reverse(Acc);
spans([{lparen, Pos} | Rest], 0, _Start, Acc) ->
    spans(Rest, 1, Pos, Acc);
spans([{lparen, _} | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth + 1, Start, Acc);
spans([{rparen, Pos} | Rest], 1, Start, Acc) ->
    spans(Rest, 0, undefined, [{Start, Pos + 1} | Acc]);
spans([{rparen, _} | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth - 1, Start, Acc);
spans([_ | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth, Start, Acc).
