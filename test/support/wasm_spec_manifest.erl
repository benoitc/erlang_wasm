%% @doc Which specification suites this runtime is expected to pass.
%%
%% The upstream test suite tracks the living specification, so it grows files
%% for proposals as they land, some of them beyond this runtime's scope.
%% Running all of them and reporting one number would say nothing useful,
%% because a failure would as easily mean "feature not implemented" as "feature
%% implemented wrongly".
%%
%% So the suites are classified. `core/0' is the set this runtime is held to;
%% everything else is named as an out-of-scope proposal, with the proposal
%% recorded so the reason for exclusion stays visible rather than becoming
%% folklore. A suite must never be moved out of `core/0' to make a build pass.
%%
%% Of the 259 suites in the checkout, 256 are core and the three that are not
%% are the text-format annotation suites. The other groups named in `groups/0'
%% have no fixtures in the pinned checkout and are listed so that they stay
%% classified if they appear. Anything *unclassified* is a suite nobody has
%% looked at yet, which is why `wasm_spec_SUITE' logs that list: 41 sat there
%% unlooked-at, and one of them was the only test of a real defect.
-module(wasm_spec_manifest).

-export([core/0, out_of_scope/0, proposal_of/1, classify/1, source_of/1]).

%% @doc Suites covering WebAssembly 1.0 plus the proposals this runtime
%% implements: sign extension, non-trapping float-to-int, bulk memory,
%% reference types, multi-value, multiple memories, memory64, SIMD, tail calls
%% typed function references, exception handling and garbage collection.
-spec core() -> [binary()].
core() ->
    [<<"address">>, <<"address0">>, <<"address1">>, <<"address64">>,
     <<"align">>, <<"align0">>, <<"align64">>, <<"array">>,
     <<"array_copy">>, <<"array_fill">>, <<"array_init_data">>,
     <<"array_init_elem">>, <<"array_new_data">>, <<"array_new_elem">>,
     <<"atomic">>, <<"binary">>, <<"binary-gc">>, <<"binary-leb128">>,
     <<"binary0">>, <<"binary_leb128_64">>, <<"block">>, <<"br">>,
     <<"br_if">>, <<"br_on_cast">>, <<"br_on_cast_fail">>,
     <<"br_on_non_null">>, <<"br_on_null">>, <<"br_table">>, <<"bulk">>,
     <<"bulk64">>, <<"call">>, <<"call_indirect">>, <<"call_indirect64">>,
     <<"call_ref">>, <<"comments">>, <<"const">>, <<"conversions">>,
     <<"custom">>, <<"data">>, <<"data0">>, <<"data1">>, <<"data_drop0">>,
     <<"elem">>, <<"endianness">>, <<"endianness64">>, <<"exports">>,
     <<"exports-threads">>, <<"exports0">>, <<"extern">>, <<"f32">>,
     <<"f32_bitwise">>, <<"f32_cmp">>, <<"f64">>, <<"f64_bitwise">>,
     <<"f64_cmp">>, <<"fac">>, <<"float_exprs">>, <<"float_exprs0">>,
     <<"float_exprs1">>, <<"float_literals">>, <<"float_memory">>,
     <<"float_memory0">>, <<"float_memory64">>, <<"float_misc">>,
     <<"forward">>, <<"func">>, <<"func_ptrs">>, <<"global">>,
     <<"i16x8_relaxed_q15mulr_s">>, <<"i31">>, <<"i32">>,
     <<"i32x4_relaxed_trunc">>, <<"i64">>, <<"i8x16_relaxed_swizzle">>,
     <<"if">>, <<"imports">>, <<"imports0">>, <<"imports1">>,
     <<"imports2">>, <<"imports3">>, <<"imports4">>, <<"inline-module">>,
     <<"instance">>, <<"int_exprs">>, <<"int_literals">>, <<"labels">>,
     <<"left-to-right">>, <<"linking">>, <<"linking0">>, <<"linking1">>,
     <<"linking2">>, <<"linking3">>, <<"load">>, <<"load0">>, <<"load1">>,
     <<"load2">>, <<"load64">>, <<"local_get">>, <<"local_init">>,
     <<"local_set">>, <<"local_tee">>, <<"loop">>, <<"memory">>,
     <<"memory-multi">>, <<"memory64">>, <<"memory64-imports">>,
     <<"memory_copy">>, <<"memory_copy0">>, <<"memory_copy1">>,
     <<"memory_copy64">>, <<"memory_fill">>, <<"memory_fill0">>,
     <<"memory_fill64">>, <<"memory_grow">>, <<"memory_grow64">>,
     <<"memory_init">>, <<"memory_init0">>, <<"memory_init64">>,
     <<"memory_redundancy">>, <<"memory_redundancy64">>,
     <<"memory_size">>, <<"memory_size0">>, <<"memory_size1">>,
     <<"memory_size2">>, <<"memory_size3">>, <<"memory_size_import">>,
     <<"memory_trap">>, <<"memory_trap0">>, <<"memory_trap1">>,
     <<"memory_trap64">>, <<"names">>, <<"nop">>, <<"ref">>,
     <<"ref_as_non_null">>, <<"ref_cast">>, <<"ref_eq">>, <<"ref_func">>,
     <<"ref_is_null">>, <<"ref_null">>, <<"ref_test">>,
     <<"relaxed_dot_product">>, <<"relaxed_laneselect">>,
     <<"relaxed_madd_nmadd">>, <<"relaxed_min_max">>, <<"return">>,
     <<"return_call">>, <<"return_call_indirect">>, <<"return_call_ref">>,
     <<"select">>, <<"simd_address">>, <<"simd_align">>,
     <<"simd_bit_shift">>, <<"simd_bitwise">>, <<"simd_boolean">>,
     <<"simd_const">>, <<"simd_conversions">>, <<"simd_f32x4">>,
     <<"simd_f32x4_arith">>, <<"simd_f32x4_cmp">>,
     <<"simd_f32x4_pmin_pmax">>, <<"simd_f32x4_rounding">>,
     <<"simd_f64x2">>, <<"simd_f64x2_arith">>, <<"simd_f64x2_cmp">>,
     <<"simd_f64x2_pmin_pmax">>, <<"simd_f64x2_rounding">>,
     <<"simd_i16x8_arith">>, <<"simd_i16x8_arith2">>,
     <<"simd_i16x8_cmp">>, <<"simd_i16x8_extadd_pairwise_i8x16">>,
     <<"simd_i16x8_extmul_i8x16">>, <<"simd_i16x8_q15mulr_sat_s">>,
     <<"simd_i16x8_sat_arith">>, <<"simd_i32x4_arith">>,
     <<"simd_i32x4_arith2">>, <<"simd_i32x4_cmp">>,
     <<"simd_i32x4_dot_i16x8">>, <<"simd_i32x4_extadd_pairwise_i16x8">>,
     <<"simd_i32x4_extmul_i16x8">>, <<"simd_i32x4_trunc_sat_f32x4">>,
     <<"simd_i32x4_trunc_sat_f64x2">>, <<"simd_i64x2_arith">>,
     <<"simd_i64x2_arith2">>, <<"simd_i64x2_cmp">>,
     <<"simd_i64x2_extmul_i32x4">>, <<"simd_i8x16_arith">>,
     <<"simd_i8x16_arith2">>, <<"simd_i8x16_cmp">>,
     <<"simd_i8x16_sat_arith">>, <<"simd_int_to_int_extend">>,
     <<"simd_lane">>, <<"simd_linking">>, <<"simd_load">>,
     <<"simd_load16_lane">>, <<"simd_load32_lane">>,
     <<"simd_load64_lane">>, <<"simd_load8_lane">>,
     <<"simd_load_extend">>, <<"simd_load_splat">>, <<"simd_load_zero">>,
     <<"simd_memory-multi">>, <<"simd_select">>, <<"simd_splat">>,
     <<"simd_store">>, <<"simd_store16_lane">>, <<"simd_store32_lane">>,
     <<"simd_store64_lane">>, <<"simd_store8_lane">>,
     <<"skip-stack-guard-page">>, <<"stack">>, <<"start">>, <<"start0">>,
     <<"store">>, <<"store0">>, <<"store1">>, <<"store2">>, <<"struct">>,
     <<"switch">>, <<"table">>, <<"table-sub">>, <<"table64">>,
     <<"table_copy">>, <<"table_copy64">>, <<"table_copy_mixed">>,
     <<"table_fill">>, <<"table_fill64">>, <<"table_get">>,
     <<"table_get64">>, <<"table_grow">>, <<"table_grow64">>,
     <<"table_init">>, <<"table_init64">>, <<"table_set">>,
     <<"table_set64">>, <<"table_size">>, <<"table_size64">>, <<"tag">>,
     <<"throw">>, <<"throw_ref">>, <<"token">>, <<"traps">>, <<"traps0">>,
     <<"try_table">>, <<"type">>, <<"type-canon">>,
     <<"type-equivalence">>, <<"type-rec">>, <<"type-subtyping">>,
     <<"unreachable">>, <<"unreached-invalid">>, <<"unreached-valid">>,
     <<"unwind">>, <<"utf8-custom-section-id">>, <<"utf8-import-field">>,
     <<"utf8-import-module">>, <<"utf8-invalid-encoding">>].

%% @doc Suites belonging to proposals outside this runtime's scope, and which
%% proposal each belongs to.
%%
%% Flat rather than nested: this list shrinks as proposals land, and a chain of
%% `maps:merge' calls means every removal has to rebalance parentheses around
%% the groups that remain.
-spec out_of_scope() -> #{binary() => atom()}.
out_of_scope() ->
    maps:from_list([{Suite, Proposal}
                    || {Proposal, Suites} <- groups(), Suite <- Suites]).

groups() ->
    [%% No fixtures in the pinned test suite.
     {gc, [<<"gc">>, <<"global-gc">>, <<"if-gc">>, <<"local_get-gc">>,
           <<"ref_null-gc">>, <<"unreached-invalid-gc">>]},
     %% The threads proposal ships its own copy of the whole core suite, and
     %% that copy predates multiple memories and multiple tables. Its
     %% `assert_invalid' cases for "multiple memories" and "multiple tables"
     %% therefore contradict a feature this runtime implements: they fail
     %% because the snapshot is old, not because anything is missing. The
     %% instructions and the shared-memory rules the proposal actually adds are
     %% in `atomic' and `exports-threads', both of which pass in full.
     {threads_stale_snapshot,
      [<<"imports-threads">>, <<"memory-threads">>]},
     {annotations, [<<"annotations">>, <<"id">>, <<"obsolete-keywords">>]},
     {custom_page_sizes,
      [<<"memory_max">>, <<"memory_max_i64">>, <<"page_size">>,
       <<"custom_page_sizes">>, <<"multi_memory">>]}].

%% @doc Where a suite's `.wast' source lives, relative to a suite checkout.
%%
%% Almost every suite is a file of its own name at the top level. Two come from
%% a proposal directory instead: the threads proposal ships the instructions
%% this runtime implements, and its copy of `exports' is suffixed so that the
%% core suite of that name keeps it.
-spec source_of(binary()) -> file:filename_all().
source_of(<<"atomic">>) -> "proposals/threads/atomic.wast";
source_of(<<"exports-threads">>) -> "proposals/threads/exports.wast";
source_of(<<"imports-threads">>) -> "proposals/threads/imports.wast";
source_of(<<"memory-threads">>) -> "proposals/threads/memory.wast";
source_of(Suite) -> binary_to_list(Suite) ++ ".wast".

-spec proposal_of(binary()) -> atom() | undefined.
proposal_of(Suite) -> maps:get(Suite, out_of_scope(), undefined).

-spec classify(binary()) -> core | {out_of_scope, atom()} | unclassified.
classify(Suite) ->
    case lists:member(Suite, core()) of
        true -> core;
        false ->
            case proposal_of(Suite) of
                undefined -> unclassified;
                P -> {out_of_scope, P}
            end
    end.
