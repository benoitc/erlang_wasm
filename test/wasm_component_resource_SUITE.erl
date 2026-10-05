-module(wasm_component_resource_SUITE).
-moduledoc """
A component that exports a resource runs through the host handle table.

The `counter` fixture is a `wit-bindgen` guest exporting a `counter` resource
with a constructor, `increment` and `get` (see
`scripts/build-component-fixture.sh`). Its core module imports the resource
built-ins `[resource-new]`/`[resource-drop]`, which the host provides: that is
the handle table. `tworesources` exports two resource types, `a` and `b`, in the
same shape, for the type checks.

A handle the host holds is a small index into the instance's table, never the
guest's representation. Using one after it was dropped, dropping it twice, or
using one that was never minted answers a `resource_not_live` trap; a handle of
one resource type where another is expected answers `resource_wrong_type`. The
guest is never called with a handle that fails a check.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_resource_is_constructed_and_its_methods_called,
     two_resources_are_independent,
     a_host_handle_is_a_small_index,
     handles_stay_small_across_constructors,
     a_method_after_drop_traps,
     a_second_drop_traps,
     a_never_minted_handle_traps,
     a_method_of_another_type_traps,
     a_destructor_of_another_type_traps,
     the_host_drop_runs_the_destructor_once,
     a_guest_drop_runs_the_destructor,
     destroy_discards_live_handles,
     handles_stay_small_across_composed_components].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path("counter")),
    {ok, Two} = file:read_file(fixture_path("tworesources")),
    [{component, Bin}, {two, Two} | Config].

end_per_suite(_Config) -> ok.

%% The instance and its handle table are scoped to the test case's process. Build the
%% cores inline (`loader => compile`) rather than through the node cache, whose 50/s load
%% limit a full test run trips when many cases instantiate.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config), #{},
                                            #{loader => compile}),
    [{inst, Inst} | Config].

end_per_testcase(_Case, _Config) -> ok.

a_resource_is_constructed_and_its_methods_called(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 5),
    ?assert(is_integer(H)),
    ?assertEqual({ok, 8}, increment(Inst, H, 3)),
    ?assertEqual({ok, 8}, get(Inst, H)),
    ?assertEqual({ok, 108}, increment(Inst, H, 100)),
    ok = drop(Inst, H).

two_resources_are_independent(Config) ->
    Inst = ?config(inst, Config),
    {ok, A} = make(Inst, 0),
    {ok, B} = make(Inst, 100),
    ?assertNotEqual(A, B),
    ?assertEqual({ok, 1}, increment(Inst, A, 1)),
    ?assertEqual({ok, 105}, increment(Inst, B, 5)),
    %% A's changes did not touch B and vice versa.
    ?assertEqual({ok, 1}, get(Inst, A)),
    ?assertEqual({ok, 105}, get(Inst, B)),
    ok = drop(Inst, A),
    ok = drop(Inst, B).

%% The first handle a fresh instance hands the host is 1, an index into its
%% table. Was 1114120: the guest's dlmalloc address, its representation.
a_host_handle_is_a_small_index(Config) ->
    Inst = ?config(inst, Config),
    ?assertEqual({ok, 1}, make(Inst, 5)),
    ?assertEqual({ok, 5}, get(Inst, 1)).

%% Handles are minted in order and never reused while the instance lives,
%% whichever export mints them and whatever descriptor the caller passes: the
%% `own` result of `[constructor]counter` is handed to the host like the `u32`
%% the caller names for `make-counter`. Was a fresh guest address each time.
handles_stay_small_across_constructors(Config) ->
    Inst = ?config(inst, Config),
    ?assertEqual({ok, 1}, make(Inst, 1)),
    ?assertEqual({ok, 2},
                 wasm_component:call(Inst, q(<<"[constructor]counter">>),
                                     {[u32], {own, 0}}, [2])),
    ok = drop(Inst, 1),
    ?assertEqual({ok, 3}, make(Inst, 3)),
    ?assertEqual({ok, 2},
                 wasm_component:call(Inst, q(<<"[method]counter.get">>),
                                     {[{borrow, 0}], u32}, [2])),
    ?assertEqual({ok, 3}, get(Inst, 3)).

%% A method on a dropped handle is refused before the guest runs. Was `{ok, 5}`:
%% the freed memory still held the value.
a_method_after_drop_traps(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 5),
    ok = drop(Inst, H),
    ?assertMatch({error, #{class := trap, kind := resource_not_live,
                           ctx := #{handle := H, operation := borrow}}},
                 get(Inst, H)),
    ?assertMatch({error, #{class := trap, kind := resource_not_live}},
                 increment(Inst, H, 1)).

%% Dropping a handle twice is refused, and the destructor is not run again.
%% Was `ok` both times.
a_second_drop_traps(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 1),
    ok = drop(Inst, H),
    ?assertMatch({error, #{class := trap, kind := resource_not_live,
                           ctx := #{handle := H, operation := drop}}},
                 drop(Inst, H)).

%% A handle the table never minted is not live: neither a method nor a drop
%% reaches the guest with it. Was a value from whatever the guest read there.
a_never_minted_handle_traps(Config) ->
    Inst = ?config(inst, Config),
    {ok, _} = make(Inst, 1),
    ?assertMatch({error, #{class := trap, kind := resource_not_live,
                           ctx := #{handle := 2}}},
                 get(Inst, 2)),
    ?assertMatch({error, #{class := trap, kind := resource_not_live}},
                 increment(Inst, 16#7FFFFFFF, 1)),
    ?assertMatch({error, #{class := trap, kind := resource_not_live}},
                 drop(Inst, 16#7FFFFFFF)).

%% `b`'s method on an `a` handle is refused by type, before the guest runs.
%% Was `{ok, 5}`: the guest read `a`'s representation as a `b`.
a_method_of_another_type_traps(Config) ->
    Two = two(Config),
    {ok, A} = two_call(Two, <<"[constructor]a">>, [5]),
    {ok, B} = two_call(Two, <<"[constructor]b">>, [6]),
    ?assertEqual({ok, 5}, two_call(Two, <<"[method]a.get">>, [A])),
    ?assertEqual({ok, 1006}, two_call(Two, <<"[method]b.get">>, [B])),
    ?assertMatch({error, #{class := trap, kind := resource_wrong_type,
                           ctx := #{expected := 1, actual := 0}}},
                 two_call(Two, <<"[method]b.get">>, [A])).

%% Dropping an `a` handle with `b`'s destructor is refused, runs no destructor,
%% and leaves the handle live for the right one. Was `ok`.
a_destructor_of_another_type_traps(Config) ->
    Two = two(Config),
    {ok, A} = two_call(Two, <<"[constructor]a">>, [5]),
    ?assertMatch({error, #{class := trap, kind := resource_wrong_type,
                           ctx := #{expected := 1, actual := 0}}},
                 two_drop(Two, <<"b">>, A)),
    ?assertEqual({ok, 0}, two_call(Two, <<"dtor-count">>, [])),
    ?assertEqual(ok, two_drop(Two, <<"a">>, A)),
    ?assertEqual({ok, 1}, two_call(Two, <<"dtor-count">>, [])).

%% A host drop runs the destructor once, with the representation; the refused
%% second drop does not run it again. Was 2: both drops called the destructor.
the_host_drop_runs_the_destructor_once(Config) ->
    Two = two(Config),
    {ok, A} = two_call(Two, <<"[constructor]a">>, [5]),
    ok = two_drop(Two, <<"a">>, A),
    {error, _} = two_drop(Two, <<"a">>, A),
    ?assertEqual({ok, 1}, two_call(Two, <<"dtor-count">>, [])).

%% `churn-a` mints an `a` and drops it inside the guest, then reads the
%% destructor count: the guest's own drop runs the destructor too. Was 0: the
%% built-in only forgot the handle.
a_guest_drop_runs_the_destructor(Config) ->
    Two = two(Config),
    ?assertEqual({ok, 1}, two_call(Two, <<"churn-a">>, [])),
    ?assertEqual({ok, 2}, two_call(Two, <<"churn-a">>, [])).

%% Destroying an instance with live handles succeeds and runs no destructor.
%% Afterwards a handle answers what the destroyed instance answers: neither a
%% method nor a drop reaches the guest. The drop was `ok`.
destroy_discards_live_handles(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 5),
    {ok, _} = make(Inst, 6),
    ?assertEqual(ok, wasm_component:destroy(Inst)),
    ?assertMatch({error, #{kind := instance_not_owned}}, get(Inst, H)),
    ?assertMatch({error, #{kind := instance_not_owned}}, drop(Inst, H)).

%% Across the composed pair the provider hands out its own small handles: `run`
%% constructs and increments a counter through the bridge (42), and the
%% provider, called directly, mints the next index in its table. Was a guest
%% address on both sides.
handles_stay_small_across_composed_components(_Config) ->
    case file:read_file(fixture_path("composed_counter")) of
        {ok, Bin} ->
            {ok, CC} = wasm_component:instantiate(
                         Bin, wasi_preview2:command(#{}), #{loader => compile}),
            try
                ?assertEqual({ok, 42},
                             wasm_component:call(CC, <<"run">>, {[], u32}, [])),
                [Provider] = [Sub || {instance, Sub} <- maps:values(
                                                           maps:get(insts, CC)),
                                     provides(Sub)],
                %% The consumer dropped its counter at the end of `run`, which
                %% released the provider's handle 1.
                ProviderId = maps:get(res_id, Provider),
                ?assertEqual([], wasm_resources:live(ProviderId)),
                Ctor = <<"test:counter/ops#[constructor]counter">>,
                Incr = <<"test:counter/ops#[method]counter.increment">>,
                U32 = {[u32], u32},
                ?assertEqual({ok, 2},
                             wasm_component:call(Provider, Ctor, U32, [9])),
                ?assertEqual({ok, 10},
                             wasm_component:call(Provider, Incr, U32, [2]))
            after
                wasm_component:destroy(CC, fun(_) -> ok end)
            end;
        {error, enoent} ->
            {skip, "composed_counter fixture not built"}
    end.

%%% -------------------------------------------------------------- helpers ---

make(Inst, Init)   -> wasm_component:call(Inst, q(<<"make-counter">>),
                                          {[u32], u32}, [Init]).
increment(Inst, H, By) ->
    wasm_component:call(Inst, q(<<"[method]counter.increment">>),
                        {[u32, u32], u32}, [H, By]).
get(Inst, H)       -> wasm_component:call(Inst, q(<<"[method]counter.get">>),
                                          {[u32], u32}, [H]).
drop(Inst, H)      -> wasm_component:drop_resource(Inst, q(<<"[dtor]counter">>), H).

q(Name) -> <<"example:counter/counters#", Name/binary>>.

two(Config) ->
    {ok, Two} = wasm_component:instantiate(?config(two, Config), #{},
                                           #{loader => compile}),
    Two.

two_call(Two, Name, Args) ->
    wasm_component:call(Two, <<"example:two/things#", Name/binary>>,
                        {[u32 || _ <- Args], u32}, Args).

two_drop(Two, Res, H) ->
    wasm_component:drop_resource(
      Two, <<"example:two/things#[dtor]", Res/binary>>, H).

%% The sub-instance of the composed pair that defines the counter.
provides(#{core := Core}) ->
    Ctor = <<"test:counter/ops#[constructor]counter">>,
    maps:is_key(Ctor, wasm:exports(Core));
provides(_Other) ->
    false.

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", Name ++ ".component.wasm"]).
