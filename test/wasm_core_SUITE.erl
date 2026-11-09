%% @doc What generated code is allowed to name, and how much of it there can be.
%%
%% Every case here is about the atom table. It is node-wide and never reclaimed,
%% so a compiler that derives a name from a module's own bytes is a permanent
%% leak that a remote attacker controls the tap on. `wasm_code_slots' makes that
%% argument for module names by writing sixteen of them out; these are the ones
%% that cannot be written out, so the argument has to be made by test instead.
-module(wasm_core_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").
-include_lib("wasm/include/wasm_memory.hrl").

-define(NEEDS_QJS, [the_bounds_cover_the_real_modules,
                    the_subset_covers_a_measured_share_of_the_real_modules]).

%% The QuickJS build is fetched, not committed: it is 1.8 MB of somebody
%% else's program. The cases that read it skip when it is absent, the same way
%% `wasm_lang_SUITE' does, rather than failing with `enoent' five times.
init_per_testcase(Case, Config) ->
    case lists:member(Case, ?NEEDS_QJS) andalso not filelib:is_regular(qjs()) of
        true ->
            {skip, "no QuickJS build: run scripts/fetch-qjs-fixture.sh"};
        false ->
            Config
    end.

end_per_testcase(_Case, _Config) -> ok.

qjs() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "qjs.wasm"]).

all() ->
    [the_pools_are_bounded_by_what_the_source_says,
     every_name_is_distinct,
     a_name_past_the_bound_is_refused_rather_than_created,
     naming_every_slot_of_every_pool_creates_no_further_atoms,
     the_bounds_cover_the_real_modules,
     every_supported_operation_reaches_an_implementation,
     a_refusal_says_which_kind_of_refusal_it_is,
     the_subset_covers_a_measured_share_of_the_real_modules,
     a_generated_function_computes_what_the_interpreter_computes,
     a_hot_instance_runs_compiled_and_answers_the_same,
     the_memory_field_indices_match_the_record,
     every_memory_access_agrees_with_the_interpreter,
     every_access_over_an_image_agrees_with_the_interpreter,
     a_caller_with_a_stale_generation_is_refused,
     compilation_does_not_block_the_call_that_triggers_it,
     everything_that_can_fail_falls_back_to_the_interpreter,
     the_core_you_can_read_is_the_core_that_is_compiled,
     a_dump_of_one_function_names_that_function,
     each_function_gets_the_calling_convention_its_callees_allow,
     calls_across_the_conventions_answer_what_the_interpreter_answers,
     a_compiled_recursion_traps_at_the_interpreters_depth,
     a_frame_that_ends_its_body_builds_no_continuation,
     only_a_call_that_can_recurse_counts_the_depth,
     an_endless_recursion_traps_in_generated_code,
     every_i32_operation_agrees_in_either_form,
     an_i32_crosses_every_boundary_unchanged,
     fib_compiles_to_one_mask_per_result].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

%%% --------------------------------------------------------------- cases ---

the_pools_are_bounded_by_what_the_source_says(_) ->
    #{max_funs := F, max_frames := K} = wasm_core:limits(),
    ?assertEqual(F + K, length(wasm_core:atoms())).

every_name_is_distinct(_) ->
    %% Two frames sharing a name along one nesting path would make a branch
    %% resolve to the wrong continuation, and Core would accept it: an inner
    %% `letrec' binding shadows an outer one rather than complaining.
    All = wasm_core:atoms(),
    ?assertEqual(length(All), length(lists:usort(All))).

a_name_past_the_bound_is_refused_rather_than_created(_) ->
    #{max_funs := F, max_frames := K} = wasm_core:limits(),
    ?assertError({limit, too_many_functions}, wasm_core:fun_name(F)),
    ?assertError({limit, too_deeply_nested}, wasm_core:frame_name(K)),
    %% And the last legal one still works, so the bound is off by nothing.
    ?assert(is_atom(wasm_core:fun_name(F - 1))),
    ?assert(is_atom(wasm_core:frame_name(K - 1))).

naming_every_slot_of_every_pool_creates_no_further_atoms(_) ->
    %% The property the whole design exists for. Names are shared by every
    %% generated module, so compiling a thousand modules costs the same atoms as
    %% compiling one, and that number is a literal in `wasm_core'.
    #{max_funs := F, max_frames := K} = wasm_core:limits(),
    _ = wasm_core:atoms(),                       % pool built before counting
    Before = erlang:system_info(atom_count),
    [_ = wasm_core:fun_name(N) || N <- lists:seq(0, F - 1)],
    [_ = wasm_core:frame_name(N) || N <- lists:seq(0, K - 1)],
    ?assertEqual(Before, erlang:system_info(atom_count)).

the_bounds_cover_the_real_modules(_) ->
    %% The bounds came from `bench/paths/subset.erl' over these two modules, and
    %% this is what says they still do. A module past a bound is interpreted
    %% rather than mis-compiled, so this failing is a coverage loss and not a
    %% correctness one -- but it should fail loudly rather than quietly stop
    %% compiling QuickJS.
    #{max_funs := MaxF, max_frames := MaxK, max_arity := MaxA} =
        wasm_core:limits(),
    [begin
         {Funs, Nesting, Arity} = shape(Parts),
         ct:log("~p: ~p functions, nesting ~p, arity bound ~p",
                [Parts, Funs, Nesting, Arity]),
         ?assert(Funs =< MaxF),
         ?assert(Nesting =< MaxK),
         ?assert(Arity =< MaxA)
     end || Parts <- [["plugin", "plugin.wasm"], ["lang", "qjs.wasm"]]].

every_supported_operation_reaches_an_implementation(_) ->
    %% The property that makes routing through `wasm_exec' worth it: generated
    %% code and the interpreter share one implementation of every operation, so
    %% they cannot diverge. This says there are no gaps in that sharing -- an
    %% operation `supported/1' accepts and `op1/2' or `op2/3' has no clause for
    %% would be a `function_clause' out of generated code at run time.
    [begin
         R = try apply_op(Op, N) catch C:E -> {C, E} end,
         ?assert(R =/= error orelse ct:fail({no_implementation, Op})),
         ?assertNotMatch({error, function_clause}, R)
     end || {Op, N} <- wasm_core:ops()].

%% Operands that are legal for every operation in the set, including the ones
%% that trap: a divisor of one divides, and a shift of one shifts. The arity
%% comes from `wasm_core:ops/0` rather than from a list here, so an operation
%% added to the wrong table is a failure and not a silent pass.
apply_op(Op, 2) -> wasm_exec:op2(Op, a(Op), b(Op));
apply_op(Op, 1) -> wasm_exec:op1(Op, a(Op)).

a(Op) -> case takes_float(Op) of true -> 6.0; false -> 6 end.
b(Op) -> case takes_float(Op) of true -> 1.0; false -> 1 end.

%% What an operation *consumes*, which is not always what it is named for. A
%% conversion is named for its result: `f64.convert_i32_u` takes an integer and
%% `i32.trunc_f64_s` takes a float, and feeding either the wrong one is a
%% `function_clause` that says nothing about whether the operation is
%% implemented.
takes_float(Op) ->
    S = atom_to_list(Op),
    Named = lists:prefix("f32_", S) orelse lists:prefix("f64_", S),
    FromInt = lists:prefix("f32_convert", S) orelse lists:prefix("f64_convert", S)
        orelse Op =:= f32_reinterpret_i32 orelse Op =:= f64_reinterpret_i64,
    FromFloat = lists:prefix("i32_trunc", S) orelse lists:prefix("i64_trunc", S)
        orelse Op =:= i32_reinterpret_f32 orelse Op =:= i64_reinterpret_f64,
    (Named andalso not FromInt) orelse FromFloat.

a_refusal_says_which_kind_of_refusal_it_is(_) ->
    %% Force-eligible mode has to tell an expected fallback from a generator
    %% defect, and `false' cannot.
    Fn = #fn{nparams = 1, defaults = []},
    ?assertMatch({ok, #{shape := pure, nesting := 0}},
                 wasm_core:can_compile(Fn, [{local_get, 0}, {i32_const, 1},
                                            i32_add])),
    ?assertMatch({ok, #{shape := reads}},
                 wasm_core:can_compile(Fn, [{i32_load, {2, 0, 0}}])),
    ?assertMatch({ok, #{shape := writes}},
                 wasm_core:can_compile(Fn, [{global_set, 0}])),
    %% A direct call is in the subset and makes the function stateful.
    ?assertMatch({ok, #{shape := writes}},
                 wasm_core:can_compile(Fn, [{local_get, 0}, {call, 3}])),
    %% An indirect one is not, and nesting is where a shallow walk would miss it.
    ?assertMatch({unsupported, {return_call, 1}},
                 wasm_core:can_compile(Fn, [{return_call, 1}])),
    ?assertMatch({unsupported, {return_call, 1}},
                 wasm_core:can_compile(Fn, [{block, 0, 0, [{return_call, 1}]}])),
    #{max_frames := MaxK} = wasm_core:limits(),
    ?assertMatch({limit, too_deeply_nested},
                 wasm_core:can_compile(Fn, nest(MaxK))),
    ?assertMatch({limit, too_many_locals},
                 wasm_core:can_compile(#fn{nparams = 200, defaults = []},
                                       [{local_get, 0}])).

nest(0) -> [nop];
nest(N) -> [{block, 0, 0, nest(N - 1)}].

the_subset_covers_a_measured_share_of_the_real_modules(_) ->
    %% Not a threshold, a record. `bench/paths/subset.erl' predicted 10.3% of
    %% QuickJS functions without calls, and this is the same claim made by the
    %% code that will actually decide it. The two disagreeing means the
    %% analysis and the oracle have drifted.
    [begin
         {Ok, Unsupported, Limit} = classify(Parts),
         Total = Ok + Unsupported + Limit,
         ct:log("~p: ~p of ~p compilable (~.1f%), ~p unsupported, ~p over a limit",
                [Parts, Ok, Total, Ok * 100 / Total, Unsupported, Limit]),
         ?assert(Ok > 0)
     end || Parts <- [["plugin", "plugin.wasm"], ["lang", "qjs.wasm"]]].

classify(Parts) ->
    {ok, Bin} = file:read_file(
                  filename:join([wasm_spec_runner:fixtures_dir() | Parts])),
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{})),
    R = lists:foldl(
          fun(F, {A, B, C}) ->
                  case wasm_core:can_compile(F, wasm_instance:compiler_ir(F, I)) of
                      {ok, _} -> {A + 1, B, C};
                      {unsupported, _} -> {A, B + 1, C};
                      {limit, _} -> {A, B, C + 1}
                  end
          end, {0, 0, 0},
          [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)]),
    ok = wasm:destroy(I),
    R.

a_generated_function_computes_what_the_interpreter_computes(_) ->
    %% The whole vertical slice: wasm IR to Core Erlang to `compile:forms/2' to
    %% `code:load_binary/3' to a call, against the interpreter running the same
    %% function on the same arguments.
    %%
    %% Hand-written rather than taken from a fixture, because a case has to say
    %% which construct it is exercising: a loop with a back edge, a block with a
    %% result crossing its boundary, a branch out of two frames, a jump table,
    %% and a trap.
    %% Flat rather than folded, so the operand order a case depends on is
    %% written down instead of inferred.
    Cases =
        [{"loop with a back edge",
          ~"(func (export \"f\") (param i32) (result i32) (local i32)
              block loop
                local.get 0 i32.eqz br_if 1
                local.get 1 local.get 0 i32.add local.set 1
                local.get 0 i32.const 1 i32.sub local.set 0
                br 0
              end end
              local.get 1)",
          [[0], [1], [10], [100]], same},
         {"operands below a frame's base",
          ~"(func (export \"f\") (param i32) (result i32)
              i32.const 100
              block (result i32)
                i32.const 7 local.get 0 br_if 0
                drop i32.const 9
              end
              i32.add)",
          [[0], [1], [-1]], same},
         {"a branch out of two frames",
          ~"(func (export \"f\") (param i32) (result i32)
              block (result i32)
                block
                  local.get 0 i32.eqz br_if 0
                  i32.const 42 br 1
                end
                i32.const 7
              end)",
          [[0], [1]], same},
         {"a jump table",
          ~"(func (export \"f\") (param i32) (result i32)
              block block block block
                local.get 0 br_table 0 1 2 3
              end i32.const 1 return
              end i32.const 2 return
              end i32.const 3 return
              end i32.const 4)",
          [[0], [1], [2], [3], [99], [-1]], same},
         {"division, which traps",
          ~"(func (export \"f\") (param i32 i32) (result i32)
              local.get 0 local.get 1 i32.div_s)",
          [[10, 3], [-10, 3], [1, 0], [-2147483648, -1]], same},
         {"select and the unary operations",
          ~"(func (export \"f\") (param i32) (result i32)
              local.get 0 i32.clz
              local.get 0 i32.popcnt
              local.get 0 i32.eqz
              select)",
          [[0], [1], [255], [-1]], same},
         {"a function that returns nothing",
          ~"(func (export \"f\") (param i32) local.get 0 drop)",
          [[0], [7]], same},
         {"memory, read and written",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32)
              i32.const 8 local.get 0 i32.store
              i32.const 8 i32.load
              i32.const 9 i32.load8_u
              i32.add)",
          [[0], [1], [65535], [-1]], same},
         {"a load out of bounds, which traps",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 i32.load)",
          [[0], [65532], [65533], [1000000]], same},
         {"a call, compiled to compiled",
          ~"(func $add (param i32 i32) (result i32)
              local.get 0 local.get 1 i32.add)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 i32.const 5 call $add
              i32.const 2 call $add)",
          [[0], [1], [-1]], same},
         {"a call into a function the compiler refused",
          ~"(table 1 funcref)
            (func $uncompilable (param i32) (result i32)
              local.get 0 table.get 0 ref.is_null)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 call $uncompilable i32.const 10 i32.add)",
          [[0]], same},
         {"recursion, which must trap rather than exhaust the heap",
          ~"(func $rec (param i32) (result i32)
              local.get 0 i32.const 1 i32.add call $rec)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 call $rec)",
          [[0]], same},
         {"an indirect call, and the traps it raises",
          ~"(type $t (func (param i32) (result i32)))
            (table 3 funcref)
            (elem (i32.const 1) $a $b)
            (func $a (type $t) local.get 0 i32.const 1 i32.add)
            (func $b (type $t) local.get 0 i32.const 2 i32.mul)
            (func (export \"f\") (param i32) (result i32)
              i32.const 7 local.get 0 call_indirect (type $t))",
          %% 0 is a null element, 1 and 2 are the two functions, 3 is past the
          %% end of the table. Every one of those is a different answer.
          [[1], [2], [0], [3], [-1]], same},
         {"a global written inside a loop",
          ~"(global $g (mut i32) (i32.const 0))
            (func (export \"f\") (param i32) (result i32)
              block loop
                local.get 0 i32.eqz br_if 1
                global.get $g local.get 0 i32.add global.set $g
                local.get 0 i32.const 1 i32.sub local.set 0
                br 0
              end end
              global.get $g)",
          [[0], [1], [10]], same},
         {"memory.fill, and the length that runs off the end",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32)
              i32.const 65532 local.get 0 local.get 0 memory.fill
              i32.const 65532 i32.load)",
          %% 4 fills the last four bytes exactly; 5 is one past the end and
          %% traps. The byte written is the parameter truncated, which is what
          %% says the `band 16#FF' happens on both paths.
          [[0], [1], [4], [5], [255], [258], [-1]], same},
         {"memory.copy, overlapping and at the boundary",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32)
              i32.const 0 i32.const 16909060 i32.store
              i32.const 2 i32.const 0 local.get 0 memory.copy
              i32.const 0 i32.load)",
          [[0], [1], [4], [65534], [65535]], same},
         {"memory.copy of nothing, past the end",
          %% The clause that was found skipping its bounds check when the
          %% length is zero. 65536 is the first address past a one-page memory
          %% and is still in range for an empty copy; 65537 is not.
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 i32.const 0 i32.const 0 memory.copy
              i32.const 1)",
          [[0], [65536], [65537], [-1]], same},
         {"memory.init and data.drop",
          ~"(memory 1)
            (data \"hello\")
            (func (export \"f\") (param i32) (result i32)
              i32.const 32 i32.const 0 local.get 0 memory.init 0
              i32.const 32 i32.load8_u)",
          %% The segment is five bytes, so 6 traps.
          [[0], [1], [5], [6]], same},
         {"a dropped segment is empty rather than absent",
          ~"(memory 1)
            (data \"hello\")
            (func (export \"f\") (param i32) (result i32)
              i32.const 32 i32.const 0 i32.const 5 memory.init 0
              data.drop 0
              i32.const 32 local.get 0 i32.const 0 memory.init 0
              i32.const 32 i32.load8_u)",
          %% A zero-length init from a dropped segment is legal; any other
          %% length traps, because the segment is now empty.
          [[0], [1]], same},
         {"memory.size and memory.grow",
          ~"(memory 1 4)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 memory.grow
              memory.size i32.add)",
          %% 3 grows to the declared maximum, 4 is one past it and answers -1
          %% rather than trapping, which is what the specification requires.
          [[0], [1], [3], [4], [-1]], fresh},
         {"the integer to f64 conversions, which are inlined",
          %% The four `wasm_core:inline1/1` open-codes rather than calling
          %% `wasm_exec:op1/2`. Signed and unsigned must differ on a negative
          %% input, which is exactly what the parameter masking that was
          %% reverted got wrong, and the i64 pair must round the way `float/1`
          %% rounds once the value stops being exact.
          ~"(func (export \"f\") (param i32) (result f64)
              local.get 0 f64.convert_i32_s
              local.get 0 f64.convert_i32_u
              f64.add
              local.get 0 i64.extend_i32_s f64.convert_i64_s f64.add
              local.get 0 i64.extend_i32_s f64.convert_i64_u f64.add)",
          [[0], [1], [-1], [-2147483648], [2147483647], [1234567]], same},
         {"float arithmetic, and the values Erlang cannot hold",
          %% Division by zero is an infinity rather than a trap, zero over zero
          %% is a NaN, and both are values this runtime represents
          %% symbolically. A compiled path that used Erlang arithmetic directly
          %% would raise `badarith` on all three.
          ~"(func (export \"f\") (param f64 f64) (result f64)
              local.get 0 local.get 1 f64.div
              local.get 0 local.get 1 f64.mul f64.add
              local.get 0 local.get 1 f64.min f64.add)",
          [[1.0, 2.0], [1.0, 0.0], [0.0, 0.0], [-1.0, 0.0],
           [1.0e308, 10.0], [-0.0, 0.0]], same},
         {"float comparisons, which answer i32",
          ~"(func (export \"f\") (param f64 f64) (result i32)
              local.get 0 local.get 1 f64.lt
              local.get 0 local.get 1 f64.ge i32.add
              local.get 0 local.get 1 f64.eq i32.add)",
          [[1.0, 2.0], [2.0, 1.0], [1.0, 1.0], [0.0, -0.0]], same},
         {"f64 loaded and stored",
          ~"(memory 1)
            (func (export \"f\") (param f64) (result f64)
              i32.const 16 local.get 0 f64.store
              i32.const 16 f64.load
              local.get 0 f64.sub
              f64.abs)",
          [[0.0], [1.5], [-1.5], [1.0e300]], same},
         {"truncation, which traps rather than saturating",
          %% `i32.trunc_f64_s` of a value outside the range traps, and of a NaN
          %% traps as well. The saturating form answers a value for both, and
          %% the two must not be confused.
          ~"(func (export \"f\") (param f64) (result i32)
              local.get 0 i32.trunc_f64_s)",
          [[1.5], [-1.5], [0.0], [2147483648.0], [-2147483904.0]], same}],
    [check(Name, Src, Args, How) || {Name, Src, Args, How} <- Cases].

check(Name, Src, ArgSets, How) ->
    Wat = iolist_to_binary(["(module ", Src, ")"]),
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    #{~"f" := {func, Target}} = I#inst.exports,

    %% The whole compilable set, as production compiles it, so that a call from
    %% one compiled function to another is a local call and a call to one the
    %% compiler refused is a crossing.
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Eligible = [{F, wasm_instance:compiler_ir(F, I)} || F <- Fns],
    Unit = [{Pos, F#fn.idx, F, IR}
            || {Pos, {F, IR}} <- lists:enumerate(
                                   0, [X || {F, IR} = X <- Eligible,
                                            element(1, wasm_core:can_compile(F, IR))
                                                =:= ok])],
    Sigs = maps:from_list([{F#fn.idx, {F#fn.nparams, F#fn.nresults}} || F <- Fns]),
    TSigs = maps:from_list(
              [{Idx, {length(Ps), length(Rs)}}
               || {Idx, T} <- lists:enumerate(0, tuple_to_list(I#inst.types)),
                  #functype{params = Ps, results = Rs} <- [functype_of(T)]]),
    ct:log("~s: ~p of ~p functions compiled", [Name, length(Unit), length(Fns)]),
    %% Without this a case whose subject the generator quietly refused still
    %% passes, having compared the interpreter against itself. Two cases below
    %% do contain a function that must be refused, but never the exported one.
    ?assert(lists:keymember(Target, 2, Unit)
            orelse ct:fail({not_compiled, Name})),

    Mod = 'wasm_code_0',
    {ok, Bin} = wasm_core:module(Mod, Unit, Sigs, TSigs),
    {module, Mod} = code:load_binary(Mod, "generated", Bin),

    [begin
         %% `same' reads the state afresh each time: the interpreted call may
         %% have written a global, and the compiled call has to start from the
         %% state the interpreted one did.
         %%
         %% `fresh' gives each side its own instance, for the operations whose
         %% effect is not confined to the `#mut{}'. `memory.grow' is the one:
         %% the page count lives in `wasm_keeper', so growing twice from one
         %% starting state answers 1 and then 2, and the two sides would differ
         %% while both being right.
         {Ii, Ic} = pair(How, M, I),
         Mut = wasm_instance:mut(Ic),
         Want = try wasm:call(Ii, ~"f", Args) catch C:E -> {C, E} end,
         %% Zero is the caller's depth and zero is the generation this module
         %% was built for, which `wasm_core:module/4` uses when nothing has
         %% claimed a slot.
         Got = try Mod:invoke(Ic, Mut, Target, Args, 0, 0)
               catch throw:{wasm_error, #{kind := K}} -> {trap, K} end,
         ct:log("~s ~p: interpreted ~p, compiled ~p", [Name, Args, Want, Got]),
         case Want of
             %% `Rs' is bound, so this is an equality check on the results and
             %% not merely a shape. The `#mut{}' the compiled path hands back
             %% is not read here; what a lost write costs is
             %% `every_memory_access_agrees_with_the_interpreter'.
             {ok, Rs} -> ?assertMatch({ok, Rs, _}, Got);
             {error, #{kind := Kind}} -> ?assertEqual({trap, Kind}, Got)
         end,
         [ok = wasm:destroy(X) || How =:= fresh, X <- [Ii, Ic]]
     end || Args <- ArgSets],
    _ = code:purge(Mod), _ = code:delete(Mod), _ = code:purge(Mod),
    ok = wasm:destroy(I).

pair(same, _M, I) -> {I, I};
pair(fresh, M, _I) ->
    {ok, A} = wasm:instantiate(M, #{}),
    {ok, B} = wasm:instantiate(M, #{}),
    {A, B}.

a_hot_instance_runs_compiled_and_answers_the_same(_) ->
    %% End to end through the public API: the same instance, the same calls, one
    %% run interpreted and one that goes hot and compiles itself.
    Wat = ~"(module (memory 1) (global $g (mut i32) (i32.const 0))
              (func (export \"f\") (param i32) (result i32) (local i32)
                block loop
                  local.get 0 i32.eqz br_if 1
                  global.get $g local.get 0 i32.add global.set $g
                  local.get 0 i32.const 1 i32.sub local.set 0
                  br 0
                end end
                i32.const 4 global.get $g i32.store
                i32.const 4 i32.load))",
    %% One module, instantiated repeatedly. The hotness counter is per module,
    %% keyed on identity, and a module built from text takes a fresh identity
    %% every time it is validated -- so eight builds would never get hot, which
    %% is correct and is not what this case is about.
    M = build(Wat),
    Want = [run(M, #{}, N) || N <- lists:seq(1, 8)],

    %% Compilation happens off the calling process, so the calls that make a
    %% module hot are *not* the calls that run compiled: they interpret, which
    %% is the whole point of doing it that way. This waits for the module to
    %% arrive and then calls again, which is what an embedder warming an
    %% instance would do.
    ok = wasm_jit:reset_counts(),
    Opts = #{compile => true, compile_after => 3},
    Got = [run(M, Opts, N) || N <- lists:seq(1, 8)],
    ?assertEqual(Want, Got),

    {ok, I} = wasm:instantiate(M, #{}, Opts),
    ok = wasm_jit:await(I, 30000),
    Warm = [wasm:call(I, ~"f", [N]) || N <- lists:seq(1, 8)],
    ok = wasm:destroy(I),
    %% One instance, so the global a compiled call writes has to persist into
    %% the next call the way an interpreted one does. `f(n)' adds the first `n'
    %% integers to it, so the answers are the running sums of those: the
    %% tetrahedral numbers, `n(n+1)(n+2)/6'. A compiled `global.set' that did
    %% not thread would answer the triangular numbers instead, and both are
    %% `{ok, [_]}'.
    ?assertEqual([{ok, [N * (N + 1) * (N + 2) div 6]} || N <- lists:seq(1, 8)],
                 Warm),

    #{compiled := C, entered := E} = wasm_jit:counts(),
    ct:log("compiled ~p functions, entered generated code ~p times", [C, E]),
    %% The point of counting: every failure in this design falls back, so a
    %% green run proves nothing unless generated code was actually reached.
    ?assert(C > 0),
    ?assert(E > 0),
    wasm_test_slots:reset().

the_memory_field_indices_match_the_record(_) ->
    %% Generated code reads a memory handle directly rather than calling in for
    %% every access, so it indexes the record by literal. A literal that
    %% disagreed with the record would read the wrong field and corrupt memory
    %% rather than fail, which is the one way this optimisation could go wrong
    %% quietly. Adding a field to `#mem{}` fails here instead.
    ?assertEqual(#{chunks => ?MEM_CHUNKS, pages => ?MEM_PAGES,
                   pages_ref => ?MEM_PAGES_REF, chunks_ref => ?MEM_CHUNKS_REF,
                   shift => ?MEM_SHIFT, img_bytes => ?MEM_IMG_BYTES,
                   image => ?MEM_IMAGE, tab => ?MEM_TAB, arena => ?MEM_ARENA,
                   size => ?MEM_SIZE},
                 wasm_memory:field_indices()).

every_memory_access_agrees_with_the_interpreter(_) ->
    %% Two implementations of one rule, pinned together.
    %%
    %% `wasm_core:decode/3` and `encode/2` generate the widening that
    %% `wasm_exec:decode_loaded/3` and `encode_stored/2` perform, and they cannot
    %% be merged because one builds Core and the other runs. Everything else in
    %% this project keeps one implementation so the paths cannot drift; here the
    %% only thing that can say they have not is a test.
    %%
    %% Every load and every store, against patterns chosen to catch a wrong
    %% width or a missing sign extension: the sign bit of each width, all ones,
    %% and values that straddle a 64-bit word boundary and so take the
    %% interpreter's path in generated code rather than the inline one.
    Addrs = [0, 1, 3, 4, 7, 8, 13, 65528],
    Vals = [0, 1, -1, 127, 128, 255, 256, 32767, 32768, 65535,
            2147483647, -2147483648, 16#7FFFFFFF, 16#DEADBEEF],
    [check(io_lib:format("~s at ~p", [Op, A]), roundtrip_wat(Op, A),
           [[V] || V <- Vals], same)
     || Op <- ["i32.load", "i32.load8_s", "i32.load8_u", "i32.load16_s",
               "i32.load16_u", "i64.load8_s", "i64.load16_u", "i64.load32_s"],
        A <- Addrs],
    ok.

%% Every store and every load, at each of the sixteen offsets on either side of
%% a 4 KiB page boundary and of the end of an image, over a memory laid on an
%% image: the first page is the image's, the second is ordinary memory after
%% it. The interpreter and generated code start from the same image, run the
%% same store, and must then agree on every load and on every byte.
every_access_over_an_image_agrees_with_the_interpreter(_) ->
    Image = << <<((I * 13) band 16#FF)>> || I <- lists:seq(0, 65535) >>,
    Stores = [{"i32.store", i32, 16#89ABCDEF}, {"i32.store8", i32, 16#1FF},
              {"i32.store16", i32, 16#8001}, {"i64.store", i64, -2},
              {"i64.store8", i64, 16#80}, {"i64.store16", i64, 16#FFFE},
              {"i64.store32", i64, 16#80000001}, {"f32.store", f32, -1.5},
              {"f64.store", f64, 2.25}],
    Loads = ["i32.load", "i32.load8_s", "i32.load8_u", "i32.load16_s",
             "i32.load16_u", "i64.load", "i64.load8_s", "i64.load8_u",
             "i64.load16_s", "i64.load16_u", "i64.load32_s", "i64.load32_u",
             "f32.load", "f64.load"],
    Addrs = [B + D || B <- [4096, 65536], D <- lists:seq(-16, 15)],
    [over_image(A, Stores, Loads, Image) || A <- Addrs],
    ok.

over_image(A, Stores, Loads, Image) ->
    Src = iolist_to_binary(
            ["(memory 2)\n",
             [["(func (export \"", S, "\") (param ", atom_to_list(T), ") i32.const ",
               integer_to_list(A), " local.get 0 ", S, ")\n"]
              || {S, T, _} <- Stores],
             [["(func (export \"", L, "\") (result ", lists:sublist(L, 3),
               ") i32.const ", integer_to_list(A), " ", L, ")\n"]
              || L <- Loads]]),
    {ok, P} = wasm_wat:module(iolist_to_binary(["(module ", Src, ")"])),
    {ok, M} = wasm_validate:module(P),
    Opts = #{memory_opts => #{0 => #{image => wasm_memory:image_of(Image)}}},
    {ok, I0} = wasm:instantiate(M, #{}, Opts),
    Fns = [F || F <- tuple_to_list(I0#inst.funcs), is_record(F, fn)],
    Unit = [{Pos, F#fn.idx, F, wasm_instance:compiler_ir(F, I0)}
            || {Pos, F} <- lists:enumerate(0, Fns)],
    Sigs = maps:from_list([{F#fn.idx, {F#fn.nparams, F#fn.nresults}} || F <- Fns]),
    Mod = 'wasm_code_0',
    {ok, Bin} = wasm_core:module(Mod, Unit, Sigs, #{}),
    {module, Mod} = code:load_binary(Mod, "generated", Bin),
    ok = wasm:destroy(I0),
    [begin
         {ok, Ii} = wasm:instantiate(M, #{}, Opts),
         {ok, Ic} = wasm:instantiate(M, #{}, Opts),
         %% Thirteen other pages made private first, so the page under test
         %% lands in a slot well into its arena chunk, where reading the
         %% table entry wrongly would land on the wrong slot.
         [ok = wasm:write_memory(X, Pg * 4096 + 2048, <<Pg>>)
          || X <- [Ii, Ic], Pg <- lists:seq(2, 14)],
         Target = fun(Name) ->
                          #{Name := {func, X}} = Ic#inst.exports, X
                  end,
         {ok, []} = wasm:call(Ii, list_to_binary(S), [V]),
         {ok, [], Mut} = Mod:invoke(Ic, wasm_instance:mut(Ic),
                                    Target(list_to_binary(S)), [V], 0, 0),
         ok = wasm_instance:set_mut(Ic, Mut),
         [begin
              {ok, Want} = wasm:call(Ii, list_to_binary(L), []),
              {ok, Got, _} = Mod:invoke(Ic, wasm_instance:mut(Ic),
                                        Target(list_to_binary(L)), [], 0, 0),
              ?assertEqual({A, S, L, Want}, {A, S, L, Got})
          end || L <- Loads],
         ?assertEqual({A, S, wasm:read_memory(Ii, 0, 2 * 65536)},
                      {A, S, wasm:read_memory(Ic, 0, 2 * 65536)}),
         [ok = wasm:destroy(X) || X <- [Ii, Ic]]
     end || {S, _T, V} <- Stores],
    _ = code:purge(Mod), _ = code:delete(Mod), _ = code:purge(Mod),
    ok.

%% Store the parameter and read it back through `Op`, so one module exercises
%% the store path and the load path at a known address.
roundtrip_wat(Op, Addr) ->
    iolist_to_binary(
      ["(memory 1)\n",
       "(func (export \"f\") (param i64) (result i64)\n",
       "  i32.const ", integer_to_list(Addr), " local.get 0 i64.store\n",
       "  i32.const ", integer_to_list(Addr), " ", Op,
       case lists:prefix("i32", Op) of true -> " i64.extend_i32_s"; false -> "" end,
       ")"]).

a_caller_with_a_stale_generation_is_refused(_) ->
    %% What makes a code slot safe to reuse.
    %%
    %% A caller reads a slot, decides which module it means, and only then
    %% calls. In that window the slot can be refilled, and nothing outside the
    %% callee can close it: a call lease is not atomic with the call, and
    %% `code:soft_purge/1` cannot see a process that has not entered yet. It
    %% also cannot see one at all, because it only purges code already marked
    %% old, which is a second reason not to build safety on it.
    %%
    %% So the generated module carries the slot generation it was built for and
    %% checks it. A caller that was overtaken holds an older one and is told
    %% `stale`, which means interpret. Without this it would run the new
    %% module's function at the old module's index, which is the wrong function
    %% and would answer rather than fail.
    Src = ~"(func (export \"f\") (param i32) (result i32)
              local.get 0 i32.const 1 i32.add)",
    Wat = iolist_to_binary(["(module ", Src, ")"]),
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    #{~"f" := {func, Target}} = I#inst.exports,
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Unit = [{Pos, F#fn.idx, F, wasm_instance:compiler_ir(F, I)}
            || {Pos, F} <- lists:enumerate(0, Fns)],
    Sigs = maps:from_list([{F#fn.idx, {F#fn.nparams, F#fn.nresults}} || F <- Fns]),
    Mod = 'wasm_code_0',
    {ok, Bin} = wasm_core:module(Mod, Unit, Sigs, #{}, full, 7),
    {module, Mod} = code:load_binary(Mod, "generated", Bin),
    Mut = wasm_instance:mut(I),

    %% The generation it was built for.
    ?assertMatch({ok, [42], _}, Mod:invoke(I, Mut, Target, [41], 0, 7)),
    %% Any other, whether the slot moved on or a caller remembered an older one.
    ?assertEqual({error, stale}, Mod:invoke(I, Mut, Target, [41], 0, 8)),
    ?assertEqual({error, stale}, Mod:invoke(I, Mut, Target, [41], 0, 6)),
    _ = code:purge(Mod), _ = code:delete(Mod), _ = code:purge(Mod),
    ok = wasm:destroy(I).

compilation_does_not_block_the_call_that_triggers_it(_) ->
    %% The defect this asynchrony exists for. Compiling QuickJS takes 46
    %% seconds; doing that inside whichever call happened to be the hot one
    %% makes the tier a latency defect however fast the code it produces is.
    %%
    %% Asserted as a bound on the *triggering* call rather than on wall time in
    %% general, because the machine this runs on carries a load average that
    %% moves by 3x. The margin is wide for the same reason.
    M = build(~"(module (func (export \"f\") (param i32) (result i32)
                  local.get 0 i32.const 1 i32.add))"),
    Opts = #{compile => true, compile_after => 1},
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    {Us, {ok, [1]}} = timer:tc(fun() -> wasm:call(I, ~"f", [0]) end),
    ct:log("the call that made it hot took ~p us", [Us]),
    ?assert(Us < 200000),
    ok = wasm_jit:await(I, 30000),
    ?assertEqual({ok, [1]}, wasm:call(I, ~"f", [0])),
    ok = wasm:destroy(I),
    wasm_test_slots:reset().

everything_that_can_fail_falls_back_to_the_interpreter(_) ->
    %% Each of these is a refusal the tier is built to make, and every one has
    %% to still answer correctly rather than fail.
    Uncompilable = build(~"(module (table 1 funcref)
                      (func (export \"f\") (param i32) (result i32)
                        local.get 0 table.get 0 ref.is_null))"),
    Compilable = build(~"(module (func (export \"f\") (param i32) (result i32)
                     local.get 0 i32.const 1 i32.add))"),
    ok = wasm_jit:reset_counts(),

    %% Nothing in the module is in the subset.
    ?assertEqual(run(Uncompilable, #{}, 0),
                 run(Uncompilable, #{compile => true, compile_after => 1}, 0)),
    ?assertEqual(0, maps:get(compiled, wasm_jit:counts())),

    %% Finite fuel is interpreted, because charging it round a compiled loop
    %% gives back what compiling it bought.
    ?assertEqual(run(Compilable, #{}, 5),
                 run(Compilable, #{compile => true, compile_after => 1,
                                   fuel => 1000000}, 5)),
    ?assertEqual(0, maps:get(entered, wasm_jit:counts())),

    %% And with the tier simply off, which is the default.
    ?assertEqual({ok, [6]}, run(Compilable, #{}, 5)),
    ?assertEqual(0, maps:get(entered, wasm_jit:counts())),
    wasm_test_slots:reset().

%% The dump is only worth having if it shows the tree that actually runs.
%%
%% `module/6` calls `forms/5` and compiles what it answers, so the two agree by
%% construction rather than by convention. This is what stops that being undone
%% later by somebody adding a step to one path and not the other: build a unit,
%% compile it both ways, and require the same bytes.
the_core_you_can_read_is_the_core_that_is_compiled(_) ->
    {I, Unit, Sigs, TSigs} = unit_of(~"(module
        (memory 1)
        (func (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 7 i32.shr_u
          local.get 0 i32.load i32.add))"),

    {ok, Core} = wasm_core:forms(wasm_code_0, Unit, Sigs, TSigs, 0),
    {ok, Direct, Bin1} = compile:forms(Core, [from_core, binary, return_errors]),
    ?assertEqual(wasm_code_0, Direct),
    {ok, Bin2} = wasm_core:module(wasm_code_0, Unit, Sigs, TSigs, full, 0),

    %% On the *code*, not on the bytes. `module/6` runs the compiler in a
    %% process it spawns itself, which needs `no_spawn_compiler_process`, and
    %% that option is recorded in the `compile_info` chunk. So the two binaries
    %% differ by one atom of metadata and by nothing else, and asserting raw
    %% equality would only be asserting that this runtime never passes the
    %% compiler an option.
    %%
    %% `beam_lib:md5/1` is the code, which is what this case is about: a step
    %% added to one path and not the other changes it, and the option does not.
    ?assertEqual(beam_lib:md5(Bin2), beam_lib:md5(Bin1)),

    %% And the metadata difference is exactly the one option, so a second one
    %% appearing later is a failure rather than a shrug.
    ?assertEqual([no_spawn_compiler_process],
                 compile_options(Bin2) -- compile_options(Bin1)),
    ?assertEqual([], compile_options(Bin1) -- compile_options(Bin2)),

    %% And the rendered text is Core Erlang naming the entry point every caller
    %% goes through, not an opaque term printed with `~p`.
    Text = unicode:characters_to_list(wasm_jit:dump(I)),
    ?assert(string:find(Text, "'invoke'/6") =/= nomatch),
    ?assert(string:find(Text, "module") =/= nomatch),
    ok = wasm:destroy(I).

compile_options(Bin) ->
    {ok, {_Mod, [{compile_info, Info}]}} =
        beam_lib:chunks(Bin, [compile_info]),
    proplists:get_value(options, Info, []).

%% A whole-module dump means counting positions to find the function you want.
%% Real modules have hundreds, so the index the module itself uses is what a
%% reader has to hand.
a_dump_of_one_function_names_that_function(_) ->
    {I, _, _, _} = unit_of(~"(module
        (func (export \"f\") (param i32) (result i32) local.get 0)
        (func (export \"g\") (param i32) (result i32) local.get 0 i32.const 1 i32.add))"),
    Whole = unicode:characters_to_list(wasm_jit:dump(I)),
    One = unicode:characters_to_list(wasm_jit:dump(I, 1)),
    ?assert(string:find(Whole, "'wasm_f_1'/1") =/= nomatch),
    %% Renumbered to position zero, because `fun_name/1` expects a dense range
    %% and filtering the middle out of a unit would otherwise leave a hole.
    ?assert(string:find(One, "'wasm_f_0'/1") =/= nomatch),
    ?assert(string:find(One, "'wasm_f_1'/1") =:= nomatch),
    ?assertEqual({error, nothing_to_compile}, wasm_jit:dump(I, 99)),
    ok = wasm:destroy(I).

%% An instance and the compiler inputs derived from it, which is what
%% `wasm_jit:generate/5` assembles before it calls the generator.
unit_of(Wat) ->
    M = build(Wat),
    {ok, I} = wasm:instantiate(M, #{}, #{}),
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Eligible = [{F, wasm_instance:compiler_ir(F, I)} || F <- Fns],
    Unit = [{Pos, F#fn.idx, F, IR} || {Pos, {F, IR}} <- lists:enumerate(0, Eligible)],
    Sigs = maps:from_list([{Idx, {F#fn.nparams, F#fn.nresults}}
                           || {Idx, F} <- lists:enumerate(0, tuple_to_list(I#inst.funcs)),
                              is_record(F, fn)]),
    {I, Unit, Sigs, #{}}.

functype_of(#functype{} = T) -> T;
functype_of(#subtype{body = #functype{} = T}) -> T;
functype_of(_) -> none.

build(Wat) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    M.

%% One instance per call, so the hotness counter -- which is per module -- is
%% what makes it compile rather than a long-lived instance.
run(M, Opts, N) ->
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    R = wasm:call(I, ~"f", [N]),
    ok = wasm:destroy(I),
    R.


%%% ------------------------------------------------------------- helpers ---


shape(Parts) ->
    {ok, Bin} = file:read_file(
                  filename:join([wasm_spec_runner:fixtures_dir() | Parts])),
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{})),
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Nesting = lists:max([0 | [nesting(wasm_instance:compiler_ir(F, I))
                              || F <- Fns]]),
    %% A continuation carries the frame's locals plus whatever operands are live
    %% across its boundary, so its arity is bounded by params plus locals plus
    %% the operand height the validator already recorded.
    Heights = [height(B) || #func{body = B} <- M#module.funcs],
    Arity = lists:max([0 | [A + H
                            || {F, H} <- lists:zip(by_index(Fns), Heights),
                               A <- [F#fn.nparams + length(F#fn.defaults)]]]),
    ok = wasm:destroy(I),
    {length(Fns), Nesting, Arity}.

%% `#fn.idx' counts imports first and `#module.funcs' holds only the defined
%% ones, so line them up by index rather than assuming an offset.
by_index(Fns) ->
    [F || {_, F} <- lists:sort([{F#fn.idx, F} || F <- Fns])].

height({validated, Ann}) -> height(Ann);
height(L) when is_list(L) -> lists:max([0 | [height(I) || I <- L]]);
height({H, I}) when is_integer(H) -> max(H, height(I));
height({H, _B, I}) when is_integer(H) -> max(H, height(I));
height({block, _, Body}) -> height(Body);
height({loop, _, Body}) -> height(Body);
height({if_, _, T, E}) -> max(height(T), height(E));
height({try_table, _, _, Body}) -> height(Body);
height(_) -> 0.

nesting(L) when is_list(L) -> lists:max([0 | [nesting(I) || I <- L]]);
nesting({block, _, _, B}) -> 1 + nesting(B);
nesting({loop, _, _, B}) -> 1 + nesting(B);
nesting({try_table, _, _, _, B}) -> 1 + nesting(B);
nesting({if_, _, _, T, E}) -> 1 + max(nesting(T), nesting(E));
nesting(_) -> 0.

%%% --------------------------------------------------- calling conventions ---
%%
%% Inside a unit a function is called one of three ways (`wasm_core`'s
%% `classify/1`): pure `f(Args)`, calls-only `f(D, Max, Args)`, or stateful
%% `f(Inst, Mut, D, Max, Args)`. These cases read the arity of every generated
%% function head as well as the answer, so they prove which convention ran.

each_function_gets_the_calling_convention_its_callees_allow(_) ->
    %% Self-recursion with no state is calls-only: one parameter plus two.
    ?assertEqual(#{0 => 2}, heads(~"(module
        (func $fib (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 2 i32.lt_u
          if (result i32) local.get 0
          else local.get 0 i32.const 1 i32.sub call $fib
               local.get 0 i32.const 2 i32.sub call $fib i32.add end))")),
    %% A chain reaching memory: `c' reads it, so `b' and `a', which reach it
    %% through calls, are stateful too; `d' calls nothing and stays pure.
    ?assertEqual(#{0 => 4, 1 => 4, 2 => 4, 3 => 1}, heads(~"(module
        (memory 1)
        (func $a (export \"f\") (param i32) (result i32)
          local.get 0 call $b local.get 0 call $d i32.add)
        (func $b (param i32) (result i32) local.get 0 call $c)
        (func $c (param i32) (result i32) local.get 0 i32.load)
        (func $d (param i32) (result i32) local.get 0 i32.const 1 i32.add))")),
    %% Mutual recursion with no state: both calls-only, decided together.
    ?assertEqual(#{0 => 2, 1 => 2}, heads(even_odd(~""))),
    %% The same pair where `odd' writes a global: both stateful.
    ?assertEqual(#{0 => 4, 1 => 4},
                 heads(even_odd(~"i32.const 1 global.set $g"))),
    %% An indirect call makes its caller stateful even if every target is
    %% pure.
    ?assertEqual(#{0 => 1, 1 => 4}, heads(~"(module
        (type $t (func (param i32) (result i32)))
        (table 1 funcref) (elem (i32.const 0) $p)
        (func $p (type $t) local.get 0 i32.const 1 i32.add)
        (func (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 0 call_indirect (type $t)))")),
    %% A stateful caller of a calls-only callee: each keeps its own.
    ?assertEqual(#{0 => 2, 1 => 4}, heads(~"(module
        (memory 1)
        (func $r (param i32) (result i32)
          local.get 0 i32.eqz if (result i32) i32.const 0
          else local.get 0 i32.const 1 i32.sub call $r end)
        (func (export \"f\") (param i32) (result i32)
          local.get 0 call $r local.get 0 i32.load i32.add))")).

%% A call that leaves the unit (to a function the compiler refused) makes its
%% caller stateful. Checked through `check/4', whose unit leaves the refused
%% function out exactly as production does.
calls_across_the_conventions_answer_what_the_interpreter_answers(_) ->
    Cases =
        [{"calls-only to calls-only, one result", even_odd(~""),
          [[0], [1], [7], [10]], #{0 => 2, 1 => 2}},
         {"calls-only to pure, two results", ~"(module
            (func $two (param i32) (result i32 i32)
              local.get 0 local.get 0 i32.const 3 i32.mul)
            (func $c (param i32) (result i32 i32)
              local.get 0 i32.eqz if (result i32 i32) local.get 0 call $two
              else local.get 0 i32.const 1 i32.sub call $c end)
            (func (export \"f\") (param i32) (result i32 i32)
              local.get 0 call $c))", [[0], [3], [5]],
          #{0 => 1, 1 => 2, 2 => 2}},
         {"calls-only, no result", ~"(module
            (func $n (param i32)
              local.get 0 i32.eqz if else local.get 0 i32.const 1 i32.sub call $n end)
            (func (export \"f\") (param i32) local.get 0 call $n))",
          [[0], [4]], #{0 => 2, 1 => 2}},
         {"stateful to calls-only and to pure", ~"(module
            (memory 1)
            (func $r (param i32) (result i32)
              local.get 0 i32.eqz if (result i32) i32.const 0
              else local.get 0 i32.const 1 i32.sub call $r end)
            (func $p (param i32) (result i32 i32) local.get 0 local.get 0)
            (func (export \"f\") (param i32) (result i32)
              i32.const 4 local.get 0 i32.store
              local.get 0 call $r local.get 0 call $p i32.add i32.add
              i32.const 4 i32.load i32.add))", [[0], [2], [9]],
          #{0 => 2, 1 => 1, 2 => 4}},
         {"stateful to stateful, threading a global", ~"(module
            (global $g (mut i32) (i32.const 0))
            (func $s (param i32) (result i32)
              global.get $g local.get 0 i32.add global.set $g global.get $g)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 call $s local.get 0 call $s i32.add))", [[1], [5]],
          #{0 => 4, 1 => 4}},
         {"stateful to stateful, two results", ~"(module
            (memory 1)
            (func $s (param i32) (result i32 i32)
              i32.const 0 local.get 0 i32.store
              i32.const 0 i32.load local.get 0 i32.const 1 i32.add)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 call $s i32.sub))", [[0], [6]],
          #{0 => 4, 1 => 4}},
         {"an indirect call whose target is calls-only", ~"(module
            (type $t (func (param i32) (result i32)))
            (table 1 funcref) (elem (i32.const 0) $r)
            (func $r (type $t)
              local.get 0 i32.eqz if (result i32) i32.const 0
              else local.get 0 i32.const 1 i32.sub call $r end)
            (func (export \"f\") (param i32) (result i32)
              local.get 0 i32.const 0 call_indirect (type $t)))", [[0], [5]],
          #{0 => 2, 1 => 4}},
         {"a calls-only function entered from outside", ~"(module
            (func $fib (export \"f\") (param i32) (result i32)
              local.get 0 i32.const 2 i32.lt_u
              if (result i32) local.get 0
              else local.get 0 i32.const 1 i32.sub call $fib
                   local.get 0 i32.const 2 i32.sub call $fib i32.add end))",
          [[0], [1], [10], [20]], #{0 => 2}}],
    %% The heads first: the answers alone would pass under the old convention
    %% too, and this case is about which convention ran.
    [begin
         ?assertEqual({Name, Heads}, {Name, heads(Wat)}),
         check_module(Name, Wat, ArgSets)
     end || {Name, Wat, ArgSets, Heads} <- Cases].

%% `max_depth => 8' on the instance, compiled against interpreted: the same
%% answer below the limit, the same error at it, with the compiled side
%% proven to have run generated code.
a_compiled_recursion_traps_at_the_interpreters_depth(_) ->
    CallsOnly = ~"(module
        (func $r (export \"f\") (param i32) (result i32)
          local.get 0 i32.eqz if (result i32) i32.const 0
          else local.get 0 i32.const 1 i32.sub call $r i32.const 1 i32.add end))",
    Stateful = ~"(module
        (global $g (mut i32) (i32.const 0))
        (func $r (export \"f\") (param i32) (result i32)
          global.get $g i32.const 1 i32.add global.set $g
          local.get 0 i32.eqz if (result i32) i32.const 0
          else local.get 0 i32.const 1 i32.sub call $r i32.const 1 i32.add end))",
    ?assertEqual(#{0 => 2}, heads(CallsOnly)),
    ?assertEqual(#{0 => 4}, heads(Stateful)),
    [begin
         M = build(Wat),
         Opts = #{compile => true, compile_whole => true, compile_sync => true,
                  compile_after => 1, max_depth => 8},
         {ok, Ic} = wasm:instantiate(M, #{}, Opts),
         _ = wasm:call(Ic, ~"f", [0]),
         {ok, Ii} = wasm:instantiate(M, #{}, #{max_depth => 8}),
         [begin
              Want = wasm:call(Ii, ~"f", [N]),
              E0 = maps:get(entered, wasm_jit:counts()),
              Got = wasm:call(Ic, ~"f", [N]),
              ?assert(maps:get(entered, wasm_jit:counts()) > E0),
              ct:log("~p: interpreted ~p, compiled ~p", [N, Want, Got]),
              ?assertEqual(same_trap(Want), same_trap(Got))
          end || N <- [5, 6, 7, 8, 9, 20]],
         %% Both sides trap somewhere in that range.
         ?assertMatch({error, #{kind := call_stack_exhausted}},
                      wasm:call(Ic, ~"f", [20])),
         ok = wasm:destroy(Ic), ok = wasm:destroy(Ii)
     end || Wat <- [CallsOnly, Stateful]],
    ok.

%% A block, loop or if with nothing after it, whose exit takes exactly its
%% results, branches to that exit: no continuation is built for it. Each case
%% counts the continuations in the generated Core, so it fails on a generator
%% that still builds one, and checks the answers against the interpreter.
a_frame_that_ends_its_body_builds_no_continuation(_) ->
    Fib = ~"(module (func $fib (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 2 i32.lt_u
          if (result i32) local.get 0
          else local.get 0 i32.const 1 i32.sub call $fib
               local.get 0 i32.const 2 i32.sub call $fib i32.add end))",
    FibThen = ~"(module (func $fib (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 2 i32.lt_u
          if (result i32) local.get 0
          else local.get 0 i32.const 1 i32.sub call $fib
               local.get 0 i32.const 2 i32.sub call $fib i32.add end
          i32.const 0 i32.add))",
    %% The loop's own header is a continuation; the one after it is not.
    Loop = ~"(module (func (export \"f\") (param i32) (result i32) (local i32)
          loop $l (result i32)
            local.get 1 local.get 0 i32.add local.set 1
            local.get 0 i32.const 1 i32.sub local.tee 0
            br_if $l
            local.get 1
          end))",
    %% The inner block ends the outer one and forwards to the outer one's
    %% continuation; `br 1' and `br 0' reach the same place.
    Nested = ~"(module (global $g (mut i32) (i32.const 0))
        (func (export \"f\") (param i32) (result i32)
          block (result i32)
            block (result i32)
              global.get $g i32.const 1 i32.add global.set $g
              i32.const 10 local.get 0 br_if 1
              drop i32.const 20 local.get 0 i32.const 1 i32.add br_if 0
              drop i32.const 30
            end
          end
          global.get $g i32.add))",
    %% Two results, a trailing block of one: the block's continuation adds the
    %% operand below it, so it must stay.
    Below = ~"(module (func (export \"f\") (param i32) (result i32 i32)
          local.get 0
          block (result i32)
            local.get 0 i32.const 3 i32.mul local.get 0 br_if 0
            drop i32.const 7
          end))",
    ?assertEqual(0, conts(Fib)),
    ?assertEqual(1, conts(FibThen)),
    ?assertEqual(1, conts(Loop)),
    ?assertEqual(1, conts(Nested)),
    ?assertEqual(1, conts(Below)),
    %% The loop counts down to zero, so it takes positive arguments only.
    Small = [[0], [1], [2], [10]],
    [check_module(Name, Wat, Args)
     || {Name, Wat, Args} <- [{fib, Fib, Small}, {fib_then, FibThen, Small},
                              {loop, Loop, [[1], [2], [5]]},
                              {nested, Nested, [[0], [1], [-1], [5]]},
                              {below, Below, [[0], [1], [-1], [5]]}]],
    ok.

%% How many continuations the generated Core defines.
conts(Wat) ->
    {I, _, _, _} = unit_of(Wat),
    Text = unicode:characters_to_list(wasm_jit:dump(I)),
    ok = wasm:destroy(I),
    case re:run(Text, "'wasm_k_[0-9]+'/[0-9]+ =", [global]) of
        {match, Ms} -> length(Ms);
        nomatch -> 0
    end.

%% A depth trap compared without its context: generated code counts the
%% frames left and reports no depth.
same_trap({error, #{class := C, kind := K, msg := M}}) -> {error, C, K, M};
same_trap(V) -> V.

%% A chain of calls that cannot recurse is not counted, so the trap can come
%% later than the interpreter's, by at most one frame per component of the
%% call graph; a recursion inside it is counted exactly.
only_a_call_that_can_recurse_counts_the_depth(_) ->
    %% f -> a -> b -> r, r recursive: three uncounted frames before r.
    Wat = ~"(module
        (func $r (param i32) (result i32)
          local.get 0 i32.eqz if (result i32) i32.const 0
          else local.get 0 i32.const 1 i32.sub call $r i32.const 1 i32.add end)
        (func $b (param i32) (result i32) local.get 0 call $r)
        (func $a (param i32) (result i32) local.get 0 call $b)
        (func (export \"f\") (param i32) (result i32) local.get 0 call $a))",
    M = build(Wat),
    Max = 16,
    Opts = #{compile => true, compile_whole => true, compile_sync => true,
             compile_after => 1, max_depth => Max},
    {ok, Ic} = wasm:instantiate(M, #{}, Opts),
    _ = wasm:call(Ic, ~"f", [0]),
    {ok, Ii} = wasm:instantiate(M, #{}, #{max_depth => Max}),
    Deepest = fun(I) ->
                      lists:last([N || N <- lists:seq(0, 2 * Max),
                                       element(1, wasm:call(I, ~"f", [N])) =:= ok])
              end,
    E0 = maps:get(entered, wasm_jit:counts()),
    Compiled = Deepest(Ic),
    ?assert(maps:get(entered, wasm_jit:counts()) > E0),
    Interpreted = Deepest(Ii),
    ct:log("deepest that answers: interpreted ~p, compiled ~p",
           [Interpreted, Compiled]),
    ?assert(Compiled >= Interpreted),
    ?assert(Compiled =< Interpreted + 3),
    ok = wasm:destroy(Ic), ok = wasm:destroy(Ii).

%% A recursion that never ends traps rather than growing the process: through
%% a call to itself, through a cycle of three functions, and through a table.
an_endless_recursion_traps_in_generated_code(_) ->
    Self = ~"(module (func $f (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add call $f))",
    Three = ~"(module
        (func $a (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add call $b)
        (func $b (param i32) (result i32) local.get 0 call $c)
        (func $c (param i32) (result i32) local.get 0 call $a))",
    Table = ~"(module (type $t (func (param i32) (result i32)))
        (table 1 funcref) (elem (i32.const 0) $f)
        (func $f (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add i32.const 0 call_indirect (type $t)))",
    Opts = #{compile => true, compile_whole => true, compile_sync => true,
             compile_after => 1, max_depth => 100},
    [begin
         {ok, I} = wasm:instantiate(build(Wat), #{}, Opts),
         _ = wasm:call(I, ~"f", [0]),
         E0 = maps:get(entered, wasm_jit:counts()),
         ?assertMatch({error, #{kind := call_stack_exhausted}},
                      bounded_call(I, ~"f", [0])),
         ?assert(maps:get(entered, wasm_jit:counts()) > E0),
         ok = wasm:destroy(I)
     end || Wat <- [Self, Three, Table]],
    ok.

%% A call in a process of its own, killed past 8 M words or 10 seconds, so a
%% generator that lost its depth check fails this suite instead of taking the
%% machine's memory.
bounded_call(I, Name, Args) ->
    {Pid, Ref} = spawn_opt(fun() -> exit({done, wasm:call(I, Name, Args)}) end,
                           [monitor, {max_heap_size, #{size => 8000000,
                                                       kill => true,
                                                       error_logger => false}}]),
    receive
        {'DOWN', Ref, process, Pid, {done, R}} -> R;
        {'DOWN', Ref, process, Pid, Why} -> {died, Why}
    after 10000 ->
            exit(Pid, kill),
            timeout
    end.

%% Inside a unit an i32 is held unsigned (`u32') in every slot and signed
%% (`canon') at every boundary. Each operation is checked with its operands in
%% each form: straight from the parameters (`u32'), from a division, whose
%% result `wasm_exec' gives `canon', and one of each.
every_i32_operation_agrees_in_either_form(_) ->
    Bin = [i32_add, i32_sub, i32_mul, i32_and, i32_or, i32_xor, i32_shl,
           i32_shr_u, i32_shr_s, i32_eq, i32_ne, i32_lt_s, i32_lt_u,
           i32_le_s, i32_le_u, i32_gt_s, i32_gt_u, i32_ge_s, i32_ge_u],
    Edge = [0, 1, -1, 2147483647, -2147483648, -7, 31, 32, 33],
    Pairs = [[A, B] || A <- Edge, B <- Edge],
    Canon = fun(L) -> ["local.get ", L, " i32.const 1 i32.div_s "] end,
    [begin
         W = wat_op(Op),
         Src = iolist_to_binary(
                 ["(func (export \"f\") (param i32 i32) (result i32 i32 i32)
                     local.get 0 local.get 1 ", W, " ",
                  Canon("0"), Canon("1"), W, " ",
                  Canon("0"), "local.get 1 ", W, ")"]),
         check(atom_to_list(Op), Src, Pairs, same)
     end || Op <- Bin],
    Unary = [{"i32.eqz", "i32", Edge},
             {"i64.extend_i32_u", "i64", Edge},
             {"i64.extend_i32_s", "i64", Edge},
             {"f64.convert_i32_u", "f64", Edge},
             {"f64.convert_i32_s", "f64", Edge}],
    [check(Op, iolist_to_binary(
                 ["(func (export \"f\") (param i32) (result ", R, " ", R, ")
                     local.get 0 ", Op, " ", Canon("0"), Op, ")"]),
           [[V] || V <- Vs], same)
     || {Op, R, Vs} <- Unary],
    check("i32.wrap_i64",
          ~"(func (export \"f\") (param i64) (result i32 i32)
              local.get 0 i32.wrap_i64
              local.get 0 i32.wrap_i64 i32.const 1 i32.add)",
          [[V] || V <- [0, -1, 4294967295, 4294967296, -4294967297,
                        9223372036854775807, -9223372036854775808]], same),
    ok.

wat_op(Op) -> string:replace(atom_to_list(Op), "_", ".").

%% Negative i32 values across each place a value changes form.
an_i32_crosses_every_boundary_unchanged(_) ->
    Vs = [[0], [1], [-1], [2147483647], [-2147483648], [-12345]],
    Cases =
        [{"a global, set and read back",
          ~"(global $g (mut i32) (i32.const 0))
            (func (export \"f\") (param i32) (result i32 i32)
              local.get 0 global.set $g global.get $g
              global.get $g i32.const 1 i32.add)", same},
         {"memory: a store, then every width of load",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32 i32 i32 i32 i32)
              i32.const 8 local.get 0 i32.store
              i32.const 8 i32.load
              i32.const 8 i32.load8_s i32.const 8 i32.load8_u
              i32.const 8 i32.load16_s i32.const 8 i32.load16_u)", same},
         {"memory at an address held unsigned, in bounds and out",
          ~"(memory 1)
            (func (export \"f\") (param i32) (result i32 i32)
              local.get 0 local.get 0 i32.store offset=4
              local.get 0 i32.load offset=4
              local.get 0 i32.const 1 i32.add i32.load8_s offset=3)", same},
         {"memory.grow and memory.size answers",
          ~"(memory 1 2)
            (func (export \"f\") (param i32) (result i32 i32 i32)
              local.get 0 i32.const 1 i32.and memory.grow
              i32.const 70000 memory.grow
              memory.size)", fresh},
         {"a call to a function the compiler refused, both ways",
          ~"(table 1 funcref)
            (func $out (param i32) (result i32)
              i32.const 0 table.get 0 drop local.get 0 i32.const 1 i32.sub)
            (func (export \"f\") (param i32) (result i32 i32)
              local.get 0 call $out
              local.get 0 call $out i32.const -1 i32.lt_s)", same},
         {"a call through a table, both ways",
          ~"(type $t (func (param i32) (result i32)))
            (table 1 funcref) (elem (i32.const 0) $neg)
            (func $neg (param i32) (result i32)
              i32.const 0 local.get 0 i32.sub)
            (func (export \"f\") (param i32) (result i32 i32)
              local.get 0 i32.const 0 call_indirect (type $t)
              local.get 0 i32.const 0 call_indirect (type $t)
              i32.const 0 i32.lt_s)", same},
         {"a call inside the unit, several results",
          ~"(func $two (param i32) (result i32 i32)
              local.get 0 i32.const -1 i32.xor local.get 0)
            (func (export \"f\") (param i32) (result i32 i32 i32)
              local.get 0 call $two i32.lt_s
              local.get 0 call $two)", same},
         {"select between the two forms",
          ~"(func (export \"f\") (param i32) (result i32 i32)
              local.get 0 local.get 0 i32.const 1 i32.div_s local.get 0
              select
              local.get 0 i32.const 1 i32.div_s local.get 0 i32.const 0
              select)", same},
         {"br_table on a negative index takes the default",
          ~"(func (export \"f\") (param i32) (result i32)
              block block block
                local.get 0 br_table 0 1 2
              end i32.const 10 return
              end i32.const 11 return
              end i32.const 12)", same},
         {"a block's result and a loop's locals",
          ~"(func (export \"f\") (param i32) (result i32 i32)
              (local $i i32) (local $acc i32)
              block (result i32)
                local.get 0 i32.const -3 i32.mul
              end
              i32.const 4 local.set $i
              loop $l
                local.get $acc local.get 0 i32.sub local.set $acc
                local.get $i i32.const 1 i32.sub local.tee $i
                br_if $l
              end
              local.get $acc)", same},
         {"SIMD lanes take and give i32",
          ~"(func (export \"f\") (param i32) (result i32 i32 i32)
              local.get 0 i32x4.splat i32x4.extract_lane 2
              v128.const i32x4 0 0 0 0 local.get 0 i32x4.replace_lane 1
              i32x4.extract_lane 1
              local.get 0 i32x4.splat i32x4.bitmask)", same}],
    [check(Name, Src, Vs ++ [[0], [8], [65528], [65529]], How)
     || {Name, Src, How} <- Cases],
    ok.

%% The point of holding an i32 unsigned: the generated `fib' wraps each
%% result with one `band' and never compares against 2^31, the bound of the
%% signed form. Fails on a generator that holds i32 signed.
fib_compiles_to_one_mask_per_result(_) ->
    Fib = ~"(module (func $fib (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 2 i32.lt_u
          if (result i32) local.get 0
          else local.get 0 i32.const 1 i32.sub call $fib
               local.get 0 i32.const 2 i32.sub call $fib i32.add end))",
    {I, _, _, _} = unit_of(Fib),
    Text = unicode:characters_to_list(wasm_jit:dump(I)),
    ok = wasm:destroy(I),
    {match, [Body]} = re:run(Text, "'wasm_f_0'/2 =(.*)",
                             [dotall, {capture, all_but_first, list}]),
    ?assertEqual(nomatch, string:find(Body, "2147483648")),
    ?assertEqual(3, length(string:split(Body, "4294967295", all)) - 1),
    check_module(fib, Fib, [[0], [1], [2], [10], [20]]).

even_odd(OddExtra) ->
    iolist_to_binary([~"(module
        (global $g (mut i32) (i32.const 0))
        (func $even (export \"f\") (param i32) (result i32)
          local.get 0 i32.eqz if (result i32) i32.const 1
          else local.get 0 i32.const 1 i32.sub call $odd end)
        (func $odd (param i32) (result i32) ", OddExtra, ~"
          local.get 0 i32.eqz if (result i32) i32.const 0
          else local.get 0 i32.const 1 i32.sub call $even end))"]).

%% Position => arity of every generated function head, from the Core
%% `wasm_jit:dump/1' prints for the whole compilable unit.
heads(Wat) ->
    {I, _, _, _} = unit_of(Wat),
    Text = unicode:characters_to_list(wasm_jit:dump(I)),
    ok = wasm:destroy(I),
    {match, Ms} = re:run(Text, "'wasm_f_([0-9]+)'/([0-9]+) =",
                         [global, {capture, all_but_first, list}]),
    maps:from_list([{list_to_integer(P), list_to_integer(A)} || [P, A] <- Ms]).

%% `check/4' over a whole module rather than a list of functions.
check_module(Name, Wat, ArgSets) ->
    <<"(module", Rest/binary>> = Wat,
    Src = binary:part(Rest, 0, byte_size(Rest) - 1),
    check(Name, Src, ArgSets, same).
