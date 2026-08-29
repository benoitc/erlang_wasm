%% @doc Garbage collection rules that are easy to get wrong, each named.
%%
%% The collector itself is in `wasm_gc_collect_SUITE'. This is the type system
%% and the object semantics: the rules whose failure modes are a module wrongly
%% accepted rather than a wrong answer, which is the half a conformance run
%% reports least legibly.
-module(wasm_gc_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(FB, 16#FB).

all() ->
    [identical_types_in_one_group_are_distinct,
     identical_types_in_separate_groups_are_the_same,
     a_forward_reference_is_unknown,
     a_final_type_cannot_be_subtyped,
     a_mutable_field_is_invariant,
     packed_fields_round_trip_through_their_width,
     ref_eq_compares_identity_not_contents,
     an_i31_allocates_nothing].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% Two structurally identical members of one recursive group are *different*
%% types. This is the rule that makes identity nominal within a group, and the
%% reason type identity could not be a structural comparison.
identical_types_in_one_group_are_distinct(_Config) ->
    {ok, Mod} = wasm:load(two_in_one_group()),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    %% A cast of the first type's value to the second must fail.
    ?assertMatch({ok, [0]}, wasm:call(Inst, ~"test_other", [])),
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"test_own", [])),
    ok = wasm:destroy(Inst).

%% Two structurally identical types in *separate* groups are the same type.
%% Iso-recursive equivalence, and the reason interning is node-wide.
identical_types_in_separate_groups_are_the_same(_Config) ->
    {ok, Mod} = wasm:load(two_separate_groups()),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"test_other", [])),
    ok = wasm:destroy(Inst).

%% Inside the type section a type may only name its own group or an earlier
%% one. A forward reference is unknown even though the index exists once the
%% section is fully decoded.
a_forward_reference_is_unknown(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := unknown_type}},
                 wasm:load(forward_reference())).

%% `final` is a promise that nothing extends this type, so declaring it a
%% supertype is an error rather than something to ignore.
a_final_type_cannot_be_subtyped(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := subtype_of_final}},
                 wasm:load(subtype_of_final())).

%% A mutable field is written through as well as read, so narrowing it in a
%% subtype would let a write through the supertype store a value the subtype's
%% own declaration forbids.
a_mutable_field_is_invariant(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := type_mismatch}},
                 wasm:load(narrowed_mutable_field())),
    %% The same narrowing on an immutable field is fine.
    ?assertMatch({ok, _}, wasm:load(narrowed_const_field())).

%% A packed field stores only its own width. Reading it back widens, and the
%% reader says whether to sign-extend, which is why `struct.get` has signed and
%% unsigned forms and the plain form is an error on a packed field.
packed_fields_round_trip_through_their_width(_Config) ->
    {ok, Inst} = instantiate(packed_module()),
    %% 0x1FF truncates to 0xFF in an i8 field: unsigned reads 255, signed -1.
    ?assertMatch({ok, [255]}, wasm:call(Inst, ~"get_u", [16#1FF])),
    ?assertMatch({ok, [-1]}, wasm:call(Inst, ~"get_s", [16#1FF])),
    ok = wasm:destroy(Inst).

%% `ref.eq` compares identity. Two structs with identical contents are not
%% equal; a reference is equal to itself.
ref_eq_compares_identity_not_contents(_Config) ->
    {ok, Inst} = instantiate(eq_module()),
    ?assertMatch({ok, [0]}, wasm:call(Inst, ~"two_alike", [])),
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"same_twice", [])),
    ok = wasm:destroy(Inst).

%% An `i31` is an immediate. Allocating a million of them must not grow the
%% object store at all, which is the whole reason the type exists.
an_i31_allocates_nothing(_Config) ->
    {ok, Inst} = instantiate(i31_module()),
    [{ok, [7]} = wasm:call(Inst, ~"roundtrip", [7]) || _ <- lists:seq(1, 200)],
    ?assertEqual(0, wasm_heap:size(wasm_instance:heap(Inst))),
    ok = wasm:destroy(Inst).

%%% --------------------------------------------------------- module builder ---

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

%% (rec (type $a (struct)) (type $b (struct)))  -- identical, but distinct
two_in_one_group() ->
    %% One recursive group is a *single* entry in the type section's vector,
    %% however many types it declares, so the count here is two and not three.
    Group = [16#4E, wasm_asm:uleb(2),
             16#5F, wasm_asm:uleb(0),
             16#5F, wasm_asm:uleb(0)],
    cast_probe([wasm_asm:uleb(2), Group,
                [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32]], 0, 1).

%% Two separate groups with the same shape: the same type.
two_separate_groups() ->
    cast_probe([wasm_asm:uleb(3),
                [16#5F, wasm_asm:uleb(0)],
                [16#5F, wasm_asm:uleb(0)],
                [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32]], 0, 1).

%% Allocates a `$make' and tests it against `$against'.
cast_probe(Types, Make, Against) ->
    Body = fun(Target) ->
               %% Sub-opcode 20 is the non-nullable `ref.test', so only the
               %% heap type follows: the nullability is in the opcode itself,
               %% not a reference-type prefix.
               <<?FB, 1, Make,                       % struct.new_default $make
                 ?FB, 20, Target,                    % ref.test (ref $target)
                 16#0B>>
           end,
    wasm_asm:module(
      [wasm_asm:section(1, Types),
       wasm_asm:func_section([2, 2]),
       wasm_asm:export_section([{~"test_other", 0, 0}, {~"test_own", 0, 1}]),
       wasm_asm:code_section([Body(Against), Body(Make)])]).

%% (type 0 (func (param (ref 1)))) (type 1 (func)) -- 1 is a later group
forward_reference() ->
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(2),
                            [16#60, wasm_asm:uleb(1), <<16#64, 1>>,
                             wasm_asm:uleb(0)],
                            [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)]])]).

subtype_of_final() ->
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(2),
                            [16#5F, wasm_asm:uleb(0)],          % final struct
                            [16#50, wasm_asm:uleb(1), wasm_asm:uleb(0),
                             16#5F, wasm_asm:uleb(0)]])]).      % sub of it

%% A supertype with one mutable anyref field, and a subtype narrowing it.
narrowed_mutable_field() -> narrowed_field(1).
narrowed_const_field() -> narrowed_field(0).

narrowed_field(Mut) ->
    Super = [16#50, wasm_asm:uleb(0),
             16#5F, wasm_asm:uleb(1), 16#6E, Mut],           % (field anyref)
    Sub = [16#50, wasm_asm:uleb(1), wasm_asm:uleb(0),
           16#5F, wasm_asm:uleb(1), 16#6B, Mut],             % (field structref)
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(2), Super, Sub])]).

%% (type $s (struct (field (mut i8)))) with signed and unsigned readers.
packed_module() ->
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(2),
                            [16#5F, wasm_asm:uleb(1), 16#78, 1],
                            [16#60, wasm_asm:uleb(1), ?I32,
                             wasm_asm:uleb(1), ?I32]]),
       wasm_asm:func_section([1, 1]),
       wasm_asm:export_section([{~"get_u", 0, 0}, {~"get_s", 0, 1}]),
       wasm_asm:code_section(
         [<<16#20, 0, ?FB, 0, 0, ?FB, 4, 0, 0, 16#0B>>,     % struct.get_u
          <<16#20, 0, ?FB, 0, 0, ?FB, 3, 0, 0, 16#0B>>])]). % struct.get_s

eq_module() ->
    Alike = <<0, ?FB, 1, 0, ?FB, 1, 0, 16#D3, 16#0B>>,
    %% One struct, stored in a local and compared with itself. The local has to
    %% be declared: `local.tee' names it, it is not implicit.
    Same = <<1, 1, 16#63, 0,                      % (local (ref null $s))
             ?FB, 1, 0, 16#22, 0, 16#20, 0, 16#D3, 16#0B>>,
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(2),
                            [16#5F, wasm_asm:uleb(0)],
                            [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32]]),
       wasm_asm:func_section([1, 1]),
       wasm_asm:export_section([{~"two_alike", 0, 0}, {~"same_twice", 0, 1}]),
       wasm_asm:section(10, [wasm_asm:uleb(2),
                             wasm_asm:uleb(byte_size(Alike)), Alike,
                             wasm_asm:uleb(byte_size(Same)), Same])]).

i31_module() ->
    Body = <<16#20, 0, ?FB, 28, ?FB, 30, 16#0B>>,   % ref.i31 ; i31.get_u
    Code = <<0, Body/binary>>,
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(1),
                            [16#60, wasm_asm:uleb(1), ?I32,
                             wasm_asm:uleb(1), ?I32]]),
       wasm_asm:func_section([0]),
       wasm_asm:export_section([{~"roundtrip", 0, 0}]),
       wasm_asm:section(10, [wasm_asm:uleb(1),
                             wasm_asm:uleb(byte_size(Code)), Code])]).
