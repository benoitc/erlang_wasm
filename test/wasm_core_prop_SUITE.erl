%% @doc Generated programs, run twice, compared.
%%
%% `wasm_prop_SUITE' generates *binaries*, which establishes that the decoder is
%% total and creates no atoms. A random binary is essentially never a valid
%% module, so nothing there exercises execution at all.
%%
%% This generates valid programs instead, over exactly the operations
%% `wasm_core:ops/0' claims the tier can compile, and requires the compiled and
%% interpreted answers to be identical. Values and traps both: a compiled
%% `i32.div_s' that failed to trap on zero would be as wrong as one that
%% returned the wrong quotient.
%%
%% This is the shape `a_generated_function_computes_what_the_interpreter_computes'
%% already has in `wasm_core_SUITE', with the inputs generated rather than
%% chosen. Hand-chosen inputs found nothing for months and the specification
%% suite found `i32.shr_u' in one run, which is the argument for both.
%%
%% Programs are expression *trees* rather than instruction streams, so every one
%% is well typed by construction and no generated program is ever discarded. The
%% operand types come from the name, and
%% `every_supported_operation_is_generated' is what stops that table drifting
%% away from `wasm_core:ops/0'.
-module(wasm_core_prop_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("wasm/include/wasm_exec.hrl").

%% Each case builds a module, compiles it for real and runs it twice, so these
%% are worth about a second each rather than a microsecond.
-define(NUMTESTS, 200).

all() ->
    [every_supported_operation_is_generated,
     compiled_agrees_with_interpreted,
     compiled_traps_where_interpreted_traps,
     shifts_agree_at_every_count].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

end_per_testcase(_, _) -> wasm_test_slots:reset().

%%% ----------------------------------------------------------------- cases ---

%% The generator must cover the whole subset, or a green run means only that
%% the operations it happens to know about agree.
%%
%% `wasm_core:ops/0' is the tier's own list. Adding an operation there without
%% teaching this module its operand types fails here, which is the same
%% discipline `every_supported_operation_reaches_an_implementation' applies to
%% the interpreter.
every_supported_operation_is_generated(_) ->
    Missing = [Op || {Op, _} <- wasm_core:ops(), sig(Op) =:= unknown],
    ?assertEqual([], Missing),
    %% And nothing in the table that the tier does not actually claim.
    Claimed = [Op || {Op, _} <- wasm_core:ops()],
    ?assertEqual([], [Op || Op <- known(), not lists:member(Op, Claimed)]),
    ct:log("~p operations generated", [length(Claimed)]).

compiled_agrees_with_interpreted(_) ->
    run_prop(?FORALL({Tree, Args}, {tree(4, i32), args()},
                     agrees(Tree, Args))).

%% Division and remainder are the operations that can fail, and a compiled form
%% that returned a value where the interpreter trapped would pass
%% `compiled_agrees_with_interpreted' only by luck of never generating a zero.
%% This generates the divisor from a set that is mostly zero.
compiled_traps_where_interpreted_traps(_) ->
    run_prop(?FORALL({Op, A, B}, {oneof(dividers()), int32(), oneof([0, 0, 0, 1, -1])},
                     agrees({Op, {param, 0}, {const, i32, B}}, [A, 0, 0.0, 0.0]))).

%% Every shift and rotate, at every count that matters, against operands whose
%% sign bit is set.
%%
%% Random generation does not find this. `i32.shr_u` was wrong only when the
%% count masked to zero and the operand was negative, which is one input class
%% in about sixty-four; 1600 generated programs did not hit it and the
%% specification suite found it on its first run. So the counts are enumerated
%% rather than sampled: 0 and the two width boundaries are where a shift stops
%% moving the sign bit down, and they are the values a wrong implementation
%% agrees with the right one everywhere else.
shifts_agree_at_every_count(_) ->
    Counts = [0, 1, 31, 32, 33, 63, 64, 65, -1, -32, 2147483647, -2147483648],
    Values = [-1, 1, 0, -2147483648, 2147483647, 16#DEADBEEF],
    Fails = [{Op, V, C}
             || Op <- shifters(), V <- Values, C <- Counts,
                not agrees({Op, {const, i32, V}, {const, i32, C}},
                           [0, 0, 0.0, 0.0])],
    ?assertEqual([], Fails),
    Fails64 = [{Op, V, C}
               || Op <- shifters64(), V <- Values, C <- Counts,
                  not agrees({Op, {const, i64, V}, {const, i64, C}},
                             [0, 0, 0.0, 0.0])],
    ?assertEqual([], Fails64).

shifters() -> [i32_shl, i32_shr_s, i32_shr_u, i32_rotl, i32_rotr].
shifters64() -> [i64_shl, i64_shr_s, i64_shr_u, i64_rotl, i64_rotr].

%%% ------------------------------------------------------------- the check ---

%% Each program in a process of its own.
%%
%% A generated module takes a fresh `reference()' for its identity and there are
%% only sixteen slots, so without this the seventeenth program of a run would
%% find them all leased and quietly interpret in both arms, agreeing with
%% itself. An instance's lease is released when the process holding it dies,
%% which is what makes one process per program the right way to reclaim them
%% rather than resetting the slot table underneath a live manager.
agrees(Tree, Args) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() -> Self ! {Ref, compare(Tree, Args)} end),
    receive
        {Ref, R} -> demonitor(Mon, [flush]), R;
        {'DOWN', Mon, process, Pid, Why} ->
            ct:pal("program died: ~p~n~s", [Why, wat(Tree)]),
            false
    end.

compare(Tree, Args) ->
    Wat = wat(Tree),
    case build(Wat) of
        {error, E} -> ct:pal("generated invalid module:~n~s~n~p", [Wat, E]), false;
        M ->
            Interpreted = call(M, #{}, Args),
            ok = wasm_jit:reset_counts(),
            Compiled = call_compiled(M, Args),
            #{entered := Entered} = wasm_jit:counts(),
            case {Interpreted =:= Compiled, Entered > 0} of
                {true, true} -> true;
                {false, _} ->
                    ct:pal("MISMATCH~n~s~nargs ~p~ninterpreted ~p~ncompiled ~p",
                           [Wat, Args, Interpreted, Compiled]),
                    false;
                %% Never reached generated code, so the comparison compared the
                %% interpreter with itself. That is not a pass.
                {_, false} ->
                    ct:pal("NOT COMPILED~n~s~ncounts ~p", [Wat, wasm_jit:counts()]),
                    false
            end
    end.

opts() ->
    #{compile => true, compile_sync => true, compile_after => 1,
      compile_whole => true, compile_force => true}.

%% The first call interprets and compiles synchronously on the way out; the
%% second is the one that runs compiled. See `wasm_jit'.
call_compiled(M, Args) ->
    {ok, I} = wasm:instantiate(M, #{}, opts()),
    _ = wasm:call(I, ~"f", Args),
    R = wasm:call(I, ~"f", Args),
    after_call(I, R).

call(M, Opts, Args) ->
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    after_call(I, wasm:call(I, ~"f", Args)).

%% The answer and the state it left: what each global holds, read as the
%% instance stores it, so a value written in the wrong form shows even when
%% `f''s own result, or a getter's, would convert it back.
after_call(I, R) ->
    Globals = (wasm_instance:mut(I))#mut.globals,
    ok = wasm:destroy(I),
    {normalise(R), Globals}.

%% Compare the value, or the class and kind of the trap. The context map carries
%% things like the instruction offset, which legitimately differ between a
%% compiled frame and an interpreted one.
normalise({ok, V}) -> {ok, V};
normalise({error, #{class := C, kind := K}}) -> {error, C, K};
normalise(Other) -> Other.

build(Wat) ->
    case wasm_wat:module(Wat) of
        {ok, P} ->
            case wasm_validate:module(P) of
                {ok, M} -> M;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

run_prop(P) ->
    ?assert(proper:quickcheck(P, [{numtests, ?NUMTESTS}, {to_file, user}])).

%%% ------------------------------------------------------------- generator ---

%% Four parameters, one of each type, so an operation of any operand type has
%% something to read that is not a constant.
args() ->
    ?LET({A, B, C, D}, {int32(), int64(), float(), float()}, [A, B, C, D]).

%% The boundary values, plus the shift counts that mask to zero. A shift by a
%% multiple of the width leaves its operand alone, which is the one case where
%% a missing sign wrap shows.
int32() -> oneof([0, 1, -1, 2147483647, -2147483648, 65535, -65536,
                  31, 32, 33, 63, 64,
                  integer(-2147483648, 2147483647)]).
int64() -> oneof([0, 1, -1, 9223372036854775807, -9223372036854775808,
                  4294967295, -4294967296, 31, 32, 63, 64, 65,
                  integer(-9223372036854775808, 9223372036854775807)]).

dividers() -> [i32_div_s, i32_div_u, i32_rem_s, i32_rem_u].

%% An expression of type `Want', at most `D' operations deep.
%%
%% At depth zero it must be a leaf, or the tree never terminates. Otherwise it
%% is an operation whose result type is the one being asked for, with a subtree
%% per operand.
tree(0, Want) -> leaf(Want);
tree(D, Want) ->
    frequency(
      [{1, leaf(Want)},
       {4, ?LET(Op, oneof(producing(Want)),
                ?LET(Kids, [tree(D - 1, T) || T <- element(1, sig(Op))],
                     list_to_tuple([Op | Kids])))},
       %% A value passed through a place where generated code may change its
       %% representation: an i32 is held unsigned in a local, a block result
       %% or a call inside the unit, and signed in a global, in memory and at
       %% every call out.
       {2, ?LET({How, Kid}, {oneof([call, indirect, global, mem, local, block]),
                             tree(D - 1, Want)},
                {through, How, Want, Kid})}]).

leaf(i32) -> oneof([{param, 0}, ?LET(V, int32(), {const, i32, V})]);
leaf(i64) -> oneof([{param, 1}, ?LET(V, int64(), {const, i64, V})]);
leaf(f32) -> oneof([{param, 2}, ?LET(V, float(), {const, f32, V})]);
leaf(f64) -> oneof([{param, 3}, ?LET(V, f64(), {const, f64, V})]).

%% Floats, often at the bounds below which compiled f64 arithmetic is inline
%% (2^1022 for a sum, 2^511 for a product, 1.0 for a divisor) and past them.
f64() -> oneof([float(), 4.49423283715579e307, 9.0e307, -9.0e307,
                6.703903964971299e153, 1.0e155, 1.0, -1.0, 0.999, -0.0,
                1.7976931348623157e308, 1.0e-310]).

%% Cached, because this is asked on every node of every generated tree and the
%% answer is a property of the source rather than of the run.
producing(Want) ->
    case persistent_term:get({?MODULE, producing, Want}, undefined) of
        undefined ->
            Ops = [Op || Op <- known(), element(2, sig(Op)) =:= Want],
            persistent_term:put({?MODULE, producing, Want}, Ops),
            Ops;
        Ops -> Ops
    end.

%%% ---------------------------------------------------------------- the wat ---

%% Every module carries a memory, one mutable global and one identity function
%% per type, and the export one local per type, so that a `through' node has
%% something to pass its value through. A module that uses none of them still
%% compiles `f' as pure or calls-only: those are decided by what `f' does.
wat(Tree) ->
    Types = ["i32", "i64", "f32", "f64"],
    iolist_to_binary(
      ["(module (memory 1)\n",
       %% Not exported: an exported mutable global is a shared cell, which
       %% the compiler refuses, and `f' would never compile.
       [["(global $g_", T, " (mut ", T, ") (", T, ".const 0))\n"] || T <- Types],
       [["(type $t_", T, " (func (param ", T, ") (result ", T, ")))\n"]
        || T <- Types],
       [["(func $id_", T, " (param ", T, ") (result ", T, ") local.get 0)\n"]
        || T <- Types],
       "(table 4 funcref)\n",
       "(elem (i32.const 0) $id_i32 $id_i64 $id_f32 $id_f64)\n",
       "(func (export \"f\") (param i32) (param i64) (param f32) (param f64)",
       " (result ", atom_to_list(type_of(Tree)), ")\n",
       [["  (local $l_", T, " ", T, ")\n"] || T <- Types],
       emit(Tree), "))"]).

type_of({param, 0}) -> i32;
type_of({param, 1}) -> i64;
type_of({param, 2}) -> f32;
type_of({param, 3}) -> f64;
type_of({const, T, _}) -> T;
type_of({through, _, T, _}) -> T;
type_of(Node) -> element(2, sig(element(1, Node))).

%% Postfix, which is what WebAssembly is: operands then the operation.
emit({param, N}) -> ["  local.get ", integer_to_list(N), "\n"];
emit({const, T, V}) ->
    ["  ", atom_to_list(T), ".const ", literal(T, V), "\n"];
emit({through, How, Type, Kid}) ->
    T = atom_to_list(Type),
    case How of
        call -> [emit(Kid), "  call $id_", T, "\n"];
        indirect -> [emit(Kid), "  i32.const ", slot(Type),
                     "\n  call_indirect (type $t_", T, ")\n"];
        global -> [emit(Kid), "  global.set $g_", T, "\n  global.get $g_", T, "\n"];
        mem -> ["  i32.const 16\n", emit(Kid), "  ", T, ".store\n",
                "  i32.const 16\n  ", T, ".load\n"];
        local -> [emit(Kid), "  local.tee $l_", T, "\n"];
        block -> ["  block (result ", T, ")\n", emit(Kid), "  end\n"]
    end;
emit(Node) ->
    [Op | Kids] = tuple_to_list(Node),
    [[emit(K) || K <- Kids], "  ", name(Op), "\n"].

%% The atom back to its text-format name: the first underscore separates the
%% type prefix and becomes a dot, and the rest stay as they are.
name(Op) ->
    [Type, Rest] = string:split(atom_to_list(Op), "_"),
    [Type, $., Rest].

slot(i32) -> "0";
slot(i64) -> "1";
slot(f32) -> "2";
slot(f64) -> "3".

literal(i32, V) -> integer_to_list(V);
literal(i64, V) -> integer_to_list(V);
literal(_, V) when is_float(V) -> io_lib:format("~.17g", [V]).

%%% ----------------------------------------------------------- the type table ---
%%
%% Operand types and result type per operation, derived from the name. Every
%% rule here is a naming convention the specification already follows, which is
%% why this is a set of patterns and not a table of 136 lines.
%%
%% `every_supported_operation_is_generated' holds it to `wasm_core:ops/0' in
%% both directions, so an operation the tier gains and this does not know about
%% fails the build rather than quietly narrowing what gets generated.

known() -> [Op || {Op, _} <- wasm_core:ops(), sig(Op) =/= unknown].

-define(IBIN, ["add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u",
               "and", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr"]).
-define(FBIN, ["add", "sub", "mul", "div", "min", "max", "copysign"]).
-define(FUN_, ["abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt"]).
-define(REL, ["eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u",
              "ge_s", "ge_u", "lt", "gt", "le", "ge"]).
-define(IUN, ["clz", "ctz", "popcnt", "extend8_s", "extend16_s", "extend32_s"]).

sig(Op) ->
    case string:split(atom_to_list(Op), "_") of
        [T, Rest] -> sig(list_to_atom(T), Rest);
        _ -> unknown
    end.

sig(T, Rest) when T =:= i32; T =:= i64 ->
    int_sig(T, Rest);
sig(T, Rest) when T =:= f32; T =:= f64 ->
    float_sig(T, Rest);
sig(_, _) ->
    unknown.

int_sig(T, R) ->
    case R of
        _ when R =:= "eqz" -> {[T], i32};
        %% A comparison answers i32 whatever it compared.
        _ -> case lists:member(R, ?REL) of
                 true -> {[T, T], i32};
                 false -> int_sig_1(T, R)
             end
    end.

int_sig_1(T, R) ->
    case lists:member(R, ?IBIN) of
        true -> {[T, T], T};
        false ->
            case lists:member(R, ?IUN) of
                true -> {[T], T};
                false -> int_convert(T, R)
            end
    end.

%% The conversions name their source in the operation: `i32.wrap_i64' takes an
%% i64, `i64.trunc_sat_f32_u' takes an f32, `i32.reinterpret_f32' takes an f32.
int_convert(T, R) ->
    case R of
        "wrap_i64" -> {[i64], T};
        "extend_i32_s" -> {[i32], T};
        "extend_i32_u" -> {[i32], T};
        "reinterpret_f32" -> {[f32], T};
        "reinterpret_f64" -> {[f64], T};
        _ ->
            case source_float(R, ["trunc_sat_", "trunc_"]) of
                {ok, From} -> {[From], T};
                error -> unknown
            end
    end.

float_sig(T, R) ->
    case lists:member(R, ?FBIN) of
        true -> {[T, T], T};
        false ->
            case lists:member(R, ?REL) of
                true -> {[T, T], i32};
                false -> float_sig_1(T, R)
            end
    end.

float_sig_1(T, R) ->
    case lists:member(R, ?FUN_) of
        true -> {[T], T};
        false ->
            case R of
                "promote_f32" -> {[f32], T};
                "demote_f64" -> {[f64], T};
                "reinterpret_i32" -> {[i32], T};
                "reinterpret_i64" -> {[i64], T};
                "convert_i32_s" -> {[i32], T};
                "convert_i32_u" -> {[i32], T};
                "convert_i64_s" -> {[i64], T};
                "convert_i64_u" -> {[i64], T};
                _ -> unknown
            end
    end.

%% `trunc_f64_s' and `trunc_sat_f32_u' both name the float width they read.
source_float(_R, []) -> error;
source_float(R, [P | Rest]) ->
    case string:prefix(R, P) of
        nomatch -> source_float(R, Rest);
        Tail ->
            case Tail of
                "f32_s" -> {ok, f32};
                "f32_u" -> {ok, f32};
                "f64_s" -> {ok, f64};
                "f64_u" -> {ok, f64};
                _ -> error
            end
    end.
