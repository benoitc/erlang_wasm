-module(wasm_snapshot_SUITE).
-moduledoc """
Initialized runtime snapshots, against reactors built from WAT.

A wrong snapshot looks exactly like a right one, which is why the governing
assertion is not "it worked": an instance restored from an image must be
**indistinguishable** from one that ran `init()` itself, compared as state and
again as behaviour.

No interpreter is needed to check any of that, and none is used: the mechanism
has no JavaScript or Python in it, and a fixture that needed one would be
testing the artifact rather than the mechanism.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").
-include("wasm_snapshot_budget.hrl").

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [every_atom_an_image_holds_exists_once_the_decoder_is_loaded,
     a_restored_instance_matches_one_that_ran_init,
     restore_does_not_run_the_start_function,
     a_restored_instance_is_isolated_from_the_image,
     self_referencing_funcrefs_are_relocated,
     an_inline_module_cannot_be_captured,
     the_forgery_is_refused,
     an_imported_memory_is_refused,
     a_reference_to_an_imported_function_is_rebound,
     a_compatibility_key_mismatch_is_refused,
     restore_reports_what_it_holds,
     an_ordinary_instance_cannot_be_captured,
     a_capture_is_refused_while_a_call_is_running,
     a_call_is_refused_while_a_capture_holds_the_instance,
     extern_is_refused_on_a_snapshotable_instance,
     destroy_during_a_capture_returns_ok,
     an_image_outlives_its_creator_if_something_acquired_first,
     a_released_image_cannot_be_restored,
     the_budget_is_charged_once_and_given_back,
     the_budget_refuses_a_capture_that_would_exceed_it,
     an_import_with_no_hook_refuses_the_capture,
     a_hook_that_keeps_something_unportable_fails_the_capture,
     a_hook_that_refuses_fails_the_capture,
     a_hook_sees_the_restored_instance,
     a_descriptor_left_open_by_init_refuses_the_capture,
     a_restore_hook_that_fails_leaves_no_instance,
     a_grown_unexported_memory_restores,
     an_exported_global_is_not_shared_between_restores,
     a_grown_table_restores,
     a_data_segment_the_guest_zeroed_stays_zero,
     a_zeroed_gap_between_runs_stays_zero,
     a_global_holding_a_host_term_refuses_the_capture,
     an_image_survives_a_file,
     a_corrupt_image_is_refused,
     a_truncated_image_is_refused,
     an_image_for_another_module_is_refused,
     an_image_over_the_ceiling_is_refused,
     a_malformed_ceiling_is_refused,
     an_image_naming_an_unknown_atom_is_refused,
     concurrent_charges_are_all_counted,
     charge_fails_closed_on_a_legacy_counter,
     charge_fails_closed_when_the_counter_is_missing,
     an_injected_external_reference_is_refused,
     an_out_of_range_funcref_is_refused,
     an_image_for_a_module_with_imported_state_is_refused,
     an_image_with_a_shared_memory_is_refused,
     a_filed_image_directory_stays_under_its_cap,
     a_purge_takes_the_half_written_files_too,
     an_unset_cap_is_the_default,
     a_set_cap_is_the_one_reported,
     a_cap_that_is_not_a_size_falls_back,
     a_raised_cap_takes_effect_at_the_next_store,
     a_lowered_cap_does_not_shrink_the_directory].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% The fixtures are **binaries**, committed, and emitted by
%% `scripts/build-snapshot-fixtures.py`. They have to be binaries: a snapshot
%% requires provenance, provenance is the cache handle, and the cache takes
%% bytes. There is no WAT-to-binary encoder here, so a module written as text
%% can never be a cached one.
%%
%% They are hand-emitted rather than compiled because the shapes are ones no
%% ordinary toolchain produces: a module whose only purpose is to import a
%% memory, and one whose only purpose is to put an imported function in a
%% table. Committed for the same reason the typed fixture is: a CI job that
%% needs a WebAssembly toolchain is one that can fail on the network.
fixture(Name) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                          atom_to_list(Name) ++ ".wasm"]),
    {ok, Bytes} = file:read_file(Path),
    {ok, Handle} = wasm:load(Bytes),
    Handle.

%% `snapshotable => true` is what allocates the lease counters, and an
%% instance without them cannot be captured at all: there would be no way to
%% prove no call was running on it. Only the initialisation instance asks for
%% it, which is why an ordinary request instance pays nothing.
%% `env` holds nothing, and saying so is the point: a module in `bindings` with
%% no hook refuses the capture, because silence means unknown and unknown means
%% no.
init(Handle, Imports) ->
    init(Handle, Imports,
         #{snapshotable => true, snapshot_hooks => #{~"env" => stateless}}).

init(Handle, Imports, Opts) ->
    {ok, Inst} = wasm:instantiate(Handle, Imports, Opts),
    {ok, []} = wasm:call(Inst, ~"init", []),
    Inst.

%%% ----------------------------------------------------------------- cases ---

a_restored_instance_matches_one_that_ran_init(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init),
    {ok, Fresh} = wasm:restore(Image, #{}, #{}),
    %% As **state**: the global `init` set, and the memory it wrote.
    ?assertEqual({ok, [1]}, wasm:call(Fresh, ~"ready", [])),
    %% And again as **behaviour**: the same call on both answers the same.
    ?assertEqual(wasm:call(Init, ~"handle", []), wasm:call(Fresh, ~"handle", [])),
    ok = wasm:destroy(Init),
    ok = wasm:destroy(Fresh).

restore_does_not_run_the_start_function(_Config) ->
    Handle = fixture(started),
    Self = self(),
    Tick = fun(_Ctx, []) -> Self ! ticked, {ok, []} end,
    Init = init(Handle, #{{~"env", ~"tick"} => Tick}),
    ?assertEqual(1, ticks()),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    {ok, Fresh} = wasm:restore(Image, #{{~"env", ~"tick"} => Tick}, #{}),
    %% **Counted at the host**, not read out of a global. The image overwrites
    %% every global, so a start function that ran again would leave no trace
    %% inside the guest at all: the first version of this case asserted on a
    %% counter the restore had already overwritten, and passed with the defect
    %% present. What survives a restore is an effect outside the guest.
    ?assertEqual(0, ticks()),
    ?assertEqual({ok, [1]}, wasm:call(Fresh, ~"starts", [])),
    ok = wasm:destroy(Fresh).

%% Drains whatever the start function's import has sent since the last call.
ticks() -> ticks(0).
ticks(N) -> receive ticked -> ticks(N + 1) after 0 -> N end.

a_restored_instance_is_isolated_from_the_image(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    %% Repeated restore-and-destroy against one image, each isolated from the
    %% last, which is the shape a worker actually produces. A restore that
    %% shared state with the image would count up.
    [begin
         {ok, I} = wasm:restore(Image, #{}, #{}),
         ?assertEqual({ok, [1235]}, wasm:call(I, ~"handle", [])),
         ok = wasm:destroy(I)
     end || _ <- lists:seq(1, 5)].

self_referencing_funcrefs_are_relocated(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    {ok, Fresh} = wasm:restore(Image, #{}, #{}),
    %% A `funcref` carries the instance it came from, and the source instance
    %% is gone. Calling **through** the table is what catches this: comparing
    %% table contents would not, because the reference would look plausible
    %% right up to the moment it was used.
    ?assertEqual({ok, [42]}, wasm:call(Fresh, ~"through_table", [])),
    ok = wasm:destroy(Fresh).

an_inline_module_cannot_be_captured(_Config) ->
    {ok, Bytes} = file:read_file(
                    filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                                   "reactor.wasm"])),
    %% `compile/1`, not `load/1`: the same bytes, through the other door.
    {ok, Mod} = wasm:compile(Bytes),
    {ok, Inst} = wasm:instantiate(Mod, #{}, #{snapshotable => true}),
    {ok, []} = wasm:call(Inst, ~"init", []),
    %% No cache entry, so nothing can say where this came from.
    ?assertMatch({error, #{kind := module_not_loaded}}, wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

the_forgery_is_refused(_Config) ->
    %% Load A under its own hash, then compile a *different* module B claiming
    %% that same name. A claim on the name succeeds, because the cache does
    %% hold something under it -- and the instance is B's.
    {wasm_module, Hash} = fixture(reactor),
    {ok, BinB} = file:read_file(
                   filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                                  "started.wasm"])),
    {ok, ModB} = wasm:compile(BinB, #{identity => {sha256, Hash}}),
    Tick = fun(_Ctx, []) -> {ok, []} end,
    {ok, InstB} = wasm:instantiate(ModB, #{{~"env", ~"tick"} => Tick},
                                   #{snapshotable => true,
                                     snapshot_hooks => #{~"env" => stateless}}),
    %% Refused, because provenance is retained rather than inferred: `ModB`
    %% never came through the cache, so it has no handle, whatever it is named.
    ?assertMatch({error, #{kind := module_not_loaded}}, wasm:snapshot(InstB)),
    ok = wasm:destroy(InstB).

an_imported_memory_is_refused(_Config) ->
    Handle = fixture(imports_memory),
    {ok, Mem} = wasm_memory:new(1),
    {ok, Inst} = wasm:instantiate(Handle, #{{~"env", ~"mem"} => Mem},
                                  #{snapshotable => true,
                                    snapshot_hooks => #{~"env" => stateless}}),
    {ok, []} = wasm:call(Inst, ~"init", []),
    %% An imported memory aliases something another holder also has, and an
    %% image cannot represent that: restoring would duplicate the state or
    %% silently share whatever the new imports happen to be.
    ?assertMatch({error, #{kind := imported_state_not_snapshottable}},
                 wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

a_reference_to_an_imported_function_is_rebound(_Config) ->
    Handle = fixture(holds_external),
    Seven = fun(_Ctx, []) -> {ok, [7]} end,
    {ok, Inst} = wasm:instantiate(Handle, #{{~"env", ~"f"} => Seven},
                                  #{snapshotable => true,
                                    snapshot_hooks => #{~"env" => stateless}}),
    {ok, []} = wasm:call(Inst, ~"init", []),
    %% A `funcref` naming an *imported* function still belongs to this
    %% instance: it names an index in this instance's function space, and the
    %% binding behind that index is reconstructed per restore. So it is
    %% captured and relocated rather than refused, and the restored instance
    %% reaches whatever the **new** imports put there.
    %%
    %% This case exists because the fixture was written to prove the opposite,
    %% and the opposite is not true. What `only_own_refs/1` refuses is a
    %% reference naming a *different* instance, which no fixture here can
    %% produce: reaching one needs an imported table or global, and both of
    %% those are already refused as imported state.
    {ok, Image} = wasm:snapshot(Inst),
    ok = wasm:destroy(Inst),
    Nine = fun(_Ctx, []) -> {ok, [9]} end,
    {ok, Fresh} = wasm:restore(Image, #{{~"env", ~"f"} => Nine},
                               #{snapshot_hooks => #{~"env" => stateless}}),
    ?assertEqual({ok, [9]}, wasm:call(Fresh, ~"through_table", [])),
    ok = wasm:destroy(Fresh).

a_compatibility_key_mismatch_is_refused(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{compatibility_key => {v, 1}}),
    ok = wasm:destroy(Init),
    ?assertMatch({error, #{kind := snapshot_incompatible}},
                 wasm:restore(Image, #{}, #{compatibility_key => {v, 2}})),
    %% And the matching one still works, so the check is a comparison rather
    %% than a refusal of everything.
    {ok, Fresh} = wasm:restore(Image, #{}, #{compatibility_key => {v, 1}}),
    ok = wasm:destroy(Fresh).

restore_reports_what_it_holds(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{version => ~"7"}),
    ok = wasm:destroy(Init),
    Info = wasm:snapshot_info(Image),
    %% What the image **retains**, not the address space it covers: an image
    %% keeps the non-zero runs, so a page holding one number is a few bytes
    %% rather than 65,536. Asserting the page size here was asserting that the
    %% whole memory was kept, which is the thing that changed.
    Bytes = maps:get(bytes, Info),
    ?assert(Bytes > 0),
    ?assert(Bytes < 65536),
    %% And it is the number the budget charges, which is the only reading of
    %% `bytes` a host can act on.
    ?assertEqual(Bytes, wasm_snapshot_owner:charged()),
    ?assertEqual(~"7", maps:get(version, Info)),
    ?assertEqual(Handle, maps:get(module, Info)).

%%% ------------------------------------------------------------ quiescence ---

an_ordinary_instance_cannot_be_captured(_Config) ->
    Handle = fixture(reactor),
    Inst = init(Handle, #{}, #{}),
    %% No lease counters, so nothing can prove no call is running. Refused by
    %% construction rather than by a check that could be wrong.
    ?assertMatch({error, #{kind := not_snapshotable}}, wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

a_capture_is_refused_while_a_call_is_running(_Config) ->
    Handle = fixture(holds_external),
    Self = self(),
    %% The host decides when this call ends, which is what holds it open.
    Blocking = fun(_Ctx, []) ->
                   Self ! blocked,
                   receive release -> {ok, [1]} end
               end,
    Inst = init(Handle, #{{~"env", ~"f"} => Blocking}),
    Caller = spawn_link(fun() -> _ = wasm:call(Inst, ~"block", []) end),
    receive blocked -> ok after 5_000 -> ct:fail(never_blocked) end,
    %% **Another process** is inside a call, and checking that *this* process
    %% is not would have said the instance was quiescent: depth is counted per
    %% process, and a handle works in another one while its creator is alive.
    ?assertMatch({error, #{kind := busy}}, wasm:snapshot(Inst)),
    Caller ! release,
    %% And once the call returns, it is capturable again, so the refusal is a
    %% state and not a verdict.
    ?assertMatch({ok, _}, until_capturable(Inst, 100)),
    ok = wasm:destroy(Inst).

a_call_is_refused_while_a_capture_holds_the_instance(_Config) ->
    Handle = fixture(reactor),
    Inst = init(Handle, #{}),
    ok = wasm_instance:begin_capture(Inst),
    %% Exclusivity has to actually exclude, so the other direction is checked
    %% too: a call arriving mid-capture is refused rather than reading state
    %% that is being copied.
    ?assertMatch({error, #{kind := instance_busy}}, wasm:call(Inst, ~"ready", [])),
    ok = wasm_instance:end_capture(Inst),
    ?assertEqual({ok, [1]}, wasm:call(Inst, ~"ready", [])),
    ok = wasm:destroy(Inst).

extern_is_refused_on_a_snapshotable_instance(_Config) ->
    Handle = fixture(reactor),
    Inst = init(Handle, #{}),
    %% A lease on `call/4` alone does not cover this: `extern/2` hands out
    %% **mutable** handles whose later use the instance never sees, so a
    %% capture could read a torn image while the state machine reported the
    %% instance quiescent.
    ?assertMatch({error, #{kind := instance_snapshotable}},
                 wasm:extern(Inst, ~"memory")),
    %% An ordinary instance is unaffected, which is the point of it being
    %% opt-in.
    Plain = init(Handle, #{}, #{}),
    ?assertMatch({ok, _}, wasm:extern(Plain, ~"memory")),
    ok = wasm:destroy(Inst),
    ok = wasm:destroy(Plain).

destroy_during_a_capture_returns_ok(_Config) ->
    Handle = fixture(reactor),
    Inst = init(Handle, #{}),
    ok = wasm_instance:begin_capture(Inst),
    %% `destroy/1`'s published contract is `ok`, and adding a busy return would
    %% break every existing caller to serve a case only this path meets. It
    %% marks and returns; the instance goes when the capture finishes.
    ?assertEqual(ok, wasm:destroy(Inst)),
    %% Not destroyed yet, and not usable either: the state is `capturing`, so a
    %% call is refused for that reason rather than because the instance is
    %% gone. A half-destroyed instance is exactly what an image must never be
    %% taken from.
    ?assertMatch({error, #{kind := instance_busy}}, wasm:call(Inst, ~"ready", [])),
    %% Ending the capture is what performs the destruction that was waiting.
    ?assertEqual(destroy_now, wasm_instance:end_capture(Inst)).

until_capturable(_Inst, 0) -> {error, never};
until_capturable(Inst, N) ->
    case wasm:snapshot(Inst) of
        {ok, _} = Ok -> Ok;
        _ -> timer:sleep(20), until_capturable(Inst, N - 1)
    end.

%%% -------------------------------------------------------- resource model ---

an_image_outlives_its_creator_if_something_acquired_first(_Config) ->
    Self = self(),
    Capturer = spawn(fun() ->
                        %% **Loaded here and nowhere else.** Module claims are
                        %% per process, so a `fixture/1` in the test process
                        %% would keep the module resident on its own and the
                        %% image's claim would never be what mattered. The
                        %% first version of this case did exactly that and
                        %% passed with the claim made for the wrong process.
                        Handle = fixture(reactor),
                        Inst = init(Handle, #{}),
                        {ok, Image} = wasm:snapshot(Inst),
                        Self ! {image, Image},
                        receive go -> ok end,
                        ok = wasm:destroy(Inst)
                    end),
    Image = receive {image, I} -> I after 5_000 -> ct:fail(no_image) end,
    %% **Acquire, then let the creator go.** A holder is dropped when its
    %% process dies, so the reverse order is a race that would pass most of the
    %% time and fail under load.
    ok = wasm:acquire(Image),
    Capturer ! go,
    Mon = erlang:monitor(process, Capturer),
    receive {'DOWN', Mon, process, Capturer, _} -> ok after 5_000 -> ct:fail(alive) end,
    %% The only claim left on the module is the image's own, made for a process
    %% whose life matches the image rather than the one that captured it.
    {ok, Fresh} = wasm:restore(Image, #{}, #{}),
    ?assertEqual({ok, [1]}, wasm:call(Fresh, ~"ready", [])),
    ok = wasm:destroy(Fresh),
    ok = wasm:release(Image).

a_released_image_cannot_be_restored(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    ?assertEqual(1, wasm_snapshot_owner:holders(wasm_snapshot:owner(Image))),
    ok = wasm:release(Image),
    %% Said plainly. Without this it would surface as `module_not_loaded`,
    %% which is true but describes the consequence rather than the cause.
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 until_invalidated(Image, 100)).

the_budget_is_charged_once_and_given_back(_Config) ->
    Handle = fixture(reactor),
    Before = wasm_snapshot_owner:charged(),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    %% Charged what the image holds, which since it keeps runs rather than
    %% whole memories is well under a page for this guest.
    Held = maps:get(bytes, wasm:snapshot_info(Image)),
    ?assert(Held > 0),
    ?assertEqual(Before + Held, wasm_snapshot_owner:charged()),
    %% A restore takes the existing image; the fresh memories it builds are an
    %% instance's and are charged to ordinary instance accounting. Charging
    %% here would make the budget mean something different depending on how
    %% many restores were in flight.
    {ok, Fresh} = wasm:restore(Image, #{}, #{}),
    ?assertEqual(Before + Held, wasm_snapshot_owner:charged()),
    ok = wasm:destroy(Fresh),
    ok = wasm:release(Image),
    ?assertEqual(Before, until_charged(Before, 100)).

the_budget_refuses_a_capture_that_would_exceed_it(_Config) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    application:set_env(wasm, max_snapshot_bytes, wasm_snapshot_owner:charged() + 1),
    try
        ?assertMatch({error, #{kind := snapshot_budget}}, wasm:snapshot(Init)),
        %% Refused as a value, and nothing charged for the refusal.
        Charged = wasm_snapshot_owner:charged(),
        ?assertMatch({error, #{kind := snapshot_budget}}, wasm:snapshot(Init)),
        ?assertEqual(Charged, wasm_snapshot_owner:charged())
    after
        application:unset_env(wasm, max_snapshot_bytes),
        ok = wasm:destroy(Init)
    end.

until_invalidated(_Image, 0) -> never;
until_invalidated(Image, N) ->
    case wasm:restore(Image, #{}, #{}) of
        {error, #{kind := snapshot_invalidated}} = E -> E;
        {ok, I} -> ok = wasm:destroy(I), timer:sleep(20),
                   until_invalidated(Image, N - 1);
        _ -> timer:sleep(20), until_invalidated(Image, N - 1)
    end.

until_charged(_Want, 0) -> wasm_snapshot_owner:charged();
until_charged(Want, N) ->
    case wasm_snapshot_owner:charged() of
        Want -> Want;
        _    -> timer:sleep(20), until_charged(Want, N - 1)
    end.

%%% ------------------------------------------------------------ the hooks ---

with_hook(Hook) ->
    #{snapshotable => true, snapshot_hooks => #{~"env" => Hook}}.

ticking(Handle, Opts) ->
    Tick = fun(_Ctx, []) -> {ok, []} end,
    init(Handle, #{{~"env", ~"tick"} => Tick}, Opts).

an_import_with_no_hook_refuses_the_capture(_Config) ->
    Handle = fixture(started),
    Inst = ticking(Handle, #{snapshotable => true}),
    %% **Silence means no**, which is the only default that stays correct when
    %% somebody adds a stateful import later and forgets to say so here. The
    %% module in question holds nothing at all, and it still has to say that.
    ?assertMatch({error, #{kind := import_not_snapshottable}},
                 wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst),
    Declared = ticking(Handle, with_hook(stateless)),
    ?assertMatch({ok, _}, wasm:snapshot(Declared)),
    ok = wasm:destroy(Declared).

a_hook_that_keeps_something_unportable_fails_the_capture(_Config) ->
    Handle = fixture(started),
    Self = self(),
    Hook = #{eligible => fun(_) -> ok end,
             %% A pid means something only in this node at this moment, and an
             %% image carrying one would restore into a reference to something
             %% already gone. The type is restricted *and* checked, because a
             %% hook free to return any term could contradict the promise that
             %% host resources are never captured.
             capture => fun(_) -> {ok, #{owner => Self}} end,
             restore => fun(_, _) -> ok end},
    Inst = ticking(Handle, with_hook(Hook)),
    ?assertMatch({error, #{kind := hook_capture_not_portable}},
                 wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

a_hook_that_refuses_fails_the_capture(_Config) ->
    Handle = fixture(started),
    Refusing = #{eligible => fun(_) ->
                                 {error, #{class => invalid, kind => busy_import,
                                           msg => ~"not now", ctx => #{}}}
                             end,
                 capture => fun(_) -> {ok, nothing} end,
                 restore => fun(_, _) -> ok end},
    Inst = ticking(Handle, with_hook(Refusing)),
    %% A hook that fails fails the capture, rather than producing an image
    %% whose import state nobody vouched for.
    ?assertMatch({error, #{kind := busy_import}}, wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

a_hook_sees_the_restored_instance(_Config) ->
    Handle = fixture(started),
    Self = self(),
    Hook = #{eligible => fun(_) -> ok end,
             capture => fun(_) -> {ok, ~"kept"} end,
             restore => fun(_Inst, Kept) -> Self ! {restored, Kept}, ok end},
    Inst = ticking(Handle, with_hook(Hook)),
    {ok, Image} = wasm:snapshot(Inst),
    ok = wasm:destroy(Inst),
    Tick = fun(_Ctx, []) -> {ok, []} end,
    {ok, Fresh} = wasm:restore(Image, #{{~"env", ~"tick"} => Tick},
                               with_hook(Hook)),
    %% The **new** instance's hooks run, with what the old one kept: imports
    %% are reconstructed per restore, and a hook restores only the guest-visible
    %% state its own module owns.
    receive {restored, Kept} -> ?assertEqual(~"kept", Kept)
    after 5_000 -> ct:fail(hook_not_called) end,
    ok = wasm:destroy(Fresh).

a_descriptor_left_open_by_init_refuses_the_capture(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "opener"),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "input.txt"), ~"x"),
    Handle = fixture(wasi_opener),
    Cfg = #{args => [~"opener"], env => #{}, dirs => [{~"/", Dir, read}]},
    Opts = #{snapshotable => true,
             snapshot_hooks =>
                 #{~"wasi_snapshot_preview1" => wasi_preview1:snapshot_hook()}},
    %% The guest opened a file during `init()` and kept it. A live descriptor
    %% is not reconstructible, so the hook refuses by name rather than letting
    %% an image restore into a reference to a file nobody opened.
    Opened = init(Handle, wasi_preview1:imports(Cfg), Opts),
    ?assertMatch({error, #{kind := wasi_descriptor_not_snapshottable}},
                 wasm:snapshot(Opened)),
    ok = wasm:destroy(Opened),
    %% The same module, the same preopens, `init()` not run: eligible. So what
    %% the refusal turns on is the descriptor, not the artifact or its mounts.
    {ok, Untouched} = wasm:instantiate(Handle, wasi_preview1:imports(Cfg), Opts),
    ?assertMatch({ok, _}, wasm:snapshot(Untouched)),
    ok = wasm:destroy(Untouched).

a_restore_hook_that_fails_leaves_no_instance(_Config) ->
    Handle = fixture(started),
    Refusing = #{eligible => fun(_) -> ok end,
                 capture  => fun(_) -> {ok, ~"kept"} end,
                 restore  => fun(_, _) ->
                                 {error, #{class => invalid, kind => no_room,
                                           msg => ~"not now", ctx => #{}}}
                             end},
    Good = Refusing#{restore => fun(_, _) -> ok end},
    Inst = ticking(Handle, with_hook(Good)),
    {ok, Image} = wasm:snapshot(Inst),
    ok = wasm:destroy(Inst),
    Tick = fun(_Ctx, []) -> {ok, []} end,
    Bindings = #{{~"env", ~"tick"} => Tick},
    %% The hook's **own** error comes back, not a raise flattened into
    %% `internal`, and the half-built instance is released rather than escaping.
    Before = wasm_keeper:resources(),
    ?assertMatch({error, #{kind := no_room}},
                 wasm:restore(Image, Bindings, with_hook(Refusing))),
    ?assertEqual(Before, wasm_keeper:resources()),
    %% The image is untouched: a failed restore is not a spent one.
    {ok, Fresh} = wasm:restore(Image, Bindings, with_hook(Good)),
    ok = wasm:destroy(Fresh).

%%% ------------------------------------- shapes a normal toolchain emits ---
%%
%% Four fixtures for four things `reactor.wasm` does not do: it exports its
%% memory, exports no global, grows nothing, and has no data section. Each of
%% the first three was a live defect that the suite could not see, and the
%% fourth guards a restore that skips what it thinks is already there.

plain(Name) ->
    Handle = fixture(Name),
    {ok, Inst} = wasm:instantiate(Handle, #{},
                                  #{snapshotable => true,
                                    snapshot_hooks => #{}}),
    {ok, _} = wasm:call(Inst, ~"init", []),
    Inst.

image_of(Inst) ->
    {ok, Image} = wasm:snapshot(Inst),
    ok = wasm:acquire(Image),
    ok = wasm:destroy(Inst),
    Image.

handled(Image) ->
    {ok, Fresh} = wasm:restore(Image, #{}, #{snapshotable => true,
                                             snapshot_hooks => #{}}),
    R = wasm:call(Fresh, ~"handle", []),
    ok = wasm:destroy(Fresh),
    R.

%% `grow/2` answers a new record, and writing through the old one used the
%% pre-grow size. Only visible on a memory the module does not export: an
%% exported one keeps its size in an atomics cell that the stale record still
%% reads correctly.
a_grown_unexported_memory_restores(_Config) ->
    Image = image_of(plain(grown_memory)),
    ?assertEqual({ok, [4242]}, handled(Image)),
    ?assertEqual({ok, [4242]}, handled(Image)).

%% A mutable global the module exports is a **cell**, and capturing the tuple
%% raw captured the source instance's cell: two restores shared one global, and
%% destroying the initialisation instance took it with them. The fixture's
%% `handle` answers the value it found and then bumps it, so a shared cell
%% counts up and an isolated one does not.
an_exported_global_is_not_shared_between_restores(_Config) ->
    Image = image_of(plain(exported_global)),
    ?assertEqual({ok, [7]}, handled(Image)),
    ?assertEqual({ok, [7]}, handled(Image)),
    ?assertEqual({ok, [7]}, handled(Image)).

%% Memories grew to fit on restore and tables did not, so a guest that called
%% `table.grow` during `init()` captured fine and could never be restored.
a_grown_table_restores(_Config) ->
    Image = image_of(plain(grown_table)),
    ?assertEqual({ok, [99]}, handled(Image)).

%% **A fresh instance is not zero.** `wasm_instance:new/3` runs the active data
%% segments before a restore sees it, so a restore that skipped the regions it
%% believed were already zero would leave the segment's byte where `init()`
%% wrote a zero. The fixture's segment fills 256 bytes with 0xAA and `init()`
%% zeroes byte 0, so the low byte of the answer is the whole assertion.
a_data_segment_the_guest_zeroed_stays_zero(_Config) ->
    Image = image_of(plain(zeroed_data)),
    Want = 0 bor (16#99 bsl 8) bor (16#AA bsl 16),
    ?assertEqual({ok, [Want]}, handled(Image)),
    ?assertEqual({ok, [Want]}, handled(Image)).

%% The case above cannot fail for the reason it names, and this one can.
%%
%% `wasm_snapshot:runs/1` aligns a run's start down to 8 and its end up to 8,
%% so the single zeroed byte above is inside the run that follows it and gets
%% written back correctly however the memory underneath was prepared. It was
%% asserting that a run is written, not that a gap is zero.
%%
%% This fixture zeroes **sixteen aligned bytes**, which fall between two runs
%% and are written by nothing. It is what says a restored memory is zero where
%% the image is zero, which is what lets `restore/4` ask `wasm_instance:new/3`
%% to skip the active data segments and lay only the runs. Against a build that
%% skips the fills while still applying the segments, this reads 16#AAAA.
a_zeroed_gap_between_runs_stays_zero(_Config) ->
    Image = image_of(plain(zeroed_gap)),
    Want = 0 bor (0 bsl 8) bor (16#99 bsl 16),
    ?assertEqual({ok, [Want]}, handled(Image)),
    ?assertEqual({ok, [Want]}, handled(Image)).

%% An external reference is whatever the embedder handed over, and none of what
%% it can be means anything outside this node. The check that was here named
%% `{externref, _}`, a term nothing constructs, so a pid went into an image
%% unremarked.
a_global_holding_a_host_term_refuses_the_capture(_Config) ->
    Handle = fixture(holds_host_value),
    Self = self(),
    Get = fun(_Ctx, []) -> {ok, [Self]} end,
    {ok, Inst} = wasm:instantiate(Handle, #{{~"env", ~"get"} => Get},
                                  #{snapshotable => true,
                                    snapshot_hooks => #{~"env" => stateless}}),
    {ok, _} = wasm:call(Inst, ~"init", []),
    ?assertMatch({error, #{kind := foreign_reference_not_snapshottable,
                           ctx := #{shape := pid}}},
                 wasm:snapshot(Inst)),
    ok = wasm:destroy(Inst).

%%% ------------------------------------------------------------- on disk ---

image_file(Config) ->
    filename:join(?config(priv_dir, Config), "image.img").

%% The whole point, in one case: capture here, restore from a file, and get
%% what the live image gave. Twice, because an image read once must serve every
%% request after it.
an_image_survives_a_file(Config) ->
    Path = image_file(Config),
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{version => ~"v1",
                                        compatibility_key => ~"k"}),
    Live = wasm:call(Init, ~"handle", []),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    ok = wasm:destroy(Init),
    {ok, Read} = wasm:load_snapshot(Path, Handle),
    ?assertEqual(~"v1", maps:get(version, wasm:snapshot_info(Read))),
    Opts = #{snapshotable => true, snapshot_hooks => #{},
             compatibility_key => ~"k"},
    {ok, A} = wasm:restore(Read, #{}, Opts),
    {ok, B} = wasm:restore(Read, #{}, Opts),
    ?assertEqual(Live, wasm:call(A, ~"handle", [])),
    ?assertEqual(Live, wasm:call(B, ~"handle", [])),
    ok = wasm:destroy(A),
    ok = wasm:destroy(B),
    ok = wasm:release(Read).

%% One flipped byte, and the digest is checked before anything in the payload
%% is used rather than after.
a_corrupt_image_is_refused(Config) ->
    Path = image_file(Config),
    Handle = written(Config, Path),
    {ok, <<Head:40/binary, B, Rest/binary>>} = file:read_file(Path),
    ok = file:write_file(Path, <<Head/binary, (B bxor 255), Rest/binary>>),
    ?assertMatch({error, #{kind := snapshot_corrupt}},
                 wasm:load_snapshot(Path, Handle)).

%% Checked against the length the header states, so a short read is a refusal
%% and not a digest over whatever arrived.
a_truncated_image_is_refused(Config) ->
    Path = image_file(Config),
    Handle = written(Config, Path),
    {ok, Bin} = file:read_file(Path),
    ok = file:write_file(Path, binary:part(Bin, 0, byte_size(Bin) - 3)),
    ?assertMatch({error, #{kind := snapshot_truncated}},
                 wasm:load_snapshot(Path, Handle)).

%% **The forgery, from the other side.** On the live path `restore/3` takes the
%% module from the image, which is what leaves no argument to forge. Off disk
%% that inverts: a file naming its own module would pick whichever resident one
%% suited it, so the caller names the module and the image must match.
an_image_for_another_module_is_refused(Config) ->
    Path = image_file(Config),
    _ = written(Config, Path),
    ?assertMatch({error, #{kind := snapshot_wrong_module}},
                 wasm:load_snapshot(Path, fixture(started))).

%% The size ceilings are operator settings, so an image larger than the
%% configured stored limit is refused before its payload is read.
an_image_over_the_ceiling_is_refused(Config) ->
    Path = image_file(Config),
    Handle = written(Config, Path),
    application:set_env(wasm, max_snapshot_stored_bytes, 8),
    try
        ?assertMatch({error, #{kind := snapshot_too_large}},
                     wasm:load_snapshot(Path, Handle))
    after
        application:unset_env(wasm, max_snapshot_stored_bytes)
    end.

%% A malformed ceiling is a named refusal, not a raise out of the public API.
a_malformed_ceiling_is_refused(Config) ->
    Path = image_file(Config),
    Handle = written(Config, Path),
    application:set_env(wasm, max_snapshot_inflated_bytes, not_a_number),
    try
        ?assertMatch({error, #{kind := snapshot_config_invalid}},
                     wasm:load_snapshot(Path, Handle))
    after
        application:unset_env(wasm, max_snapshot_inflated_bytes)
    end.

%% **Nothing a file supplies becomes an atom.** The name is replaced with one
%% of the same length that this node has never seen, and the digest recomputed,
%% so the refusal is the atom check rather than the corruption check. The
%% header layout is known here on purpose: a case that could not build a valid
%% image with one bad field could not test this at all.
an_image_naming_an_unknown_atom_is_refused(Config) ->
    Path = image_file(Config),
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{version => ~"v1",
                                        compatibility_key => known_atom()}),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    ok = wasm:destroy(Init),
    {ok, Bin} = file:read_file(Path),
    %% magic 8, format 2, ABI 4, payload length 4, then the digest.
    <<Head:18/binary, _Digest:32/binary, Payload/binary>> = Bin,
    Known = atom_to_binary(known_atom(), utf8),
    Unknown = <<"qqq_absent_in_this_node_alwayss">>,
    ?assertEqual(byte_size(Known), byte_size(Unknown)),
    Patched = binary:replace(Payload, Known, Unknown),
    ?assertNotEqual(Payload, Patched),
    ok = file:write_file(Path, <<Head/binary,
                                 (crypto:hash(sha256, Patched))/binary,
                                 Patched/binary>>),
    ?assertMatch({error, #{kind := snapshot_unknown_atom}},
                 wasm:load_snapshot(Path, Handle)).

known_atom() -> zzz_present_in_this_node_always.

%% The counter is seeded once, deterministically, so concurrent charges all
%% land on the same `atomics' cell and none is lost. The old lazy creation
%% raced two `atomics:new' calls and dropped charges against the loser.
concurrent_charges_are_all_counted(_Config) ->
    Base = wasm_snapshot_owner:charged(),
    N = 200,
    Self = self(),
    Pids = [spawn(fun() ->
                          ok = wasm_snapshot_owner:charge(1),
                          Self ! {done, self()}
                  end) || _ <- lists:seq(1, N)],
    [receive {done, P} -> ok after 5000 -> ct:fail(timeout) end || P <- Pids],
    ?assertEqual(Base + N, wasm_snapshot_owner:charged()),
    _ = wasm_snapshot_owner:refund(N),
    ?assertEqual(Base, wasm_snapshot_owner:charged()).

%% A counter an older, racy build left is not trusted after an upgrade: a new
%% charge fails closed by name, and the diagnostics never raise.
charge_fails_closed_on_a_legacy_counter(_Config) ->
    with_counter({legacy_bare_ref, atomics:new(1, [])},
                 fun() ->
                         ?assertMatch({error, #{kind := snapshot_counter_untrusted}},
                                      wasm_snapshot_owner:charge(1)),
                         ?assertEqual(0, wasm_snapshot_owner:charged()),
                         ?assertEqual(0, wasm_snapshot_owner:refund(1))
                 end).

%% Reachable on a hot upgrade where the old build never created its lazy
%% counter: the application is up but the counter is absent.
charge_fails_closed_when_the_counter_is_missing(_Config) ->
    Saved = persistent_term:get(?SNAPSHOT_BUDGET_KEY),
    _ = persistent_term:erase(?SNAPSHOT_BUDGET_KEY),
    try
        ?assertMatch({error, #{kind := snapshot_counter_uninitialised}},
                     wasm_snapshot_owner:charge(1)),
        ?assertEqual(0, wasm_snapshot_owner:charged()),
        ?assertEqual(0, wasm_snapshot_owner:refund(1))
    after
        persistent_term:put(?SNAPSHOT_BUDGET_KEY, Saved)
    end.

%% Swap the counter for a given value, run F, and restore the real one so the
%% node's live budget is untouched.
with_counter(Value, F) ->
    Saved = persistent_term:get(?SNAPSHOT_BUDGET_KEY),
    _ = persistent_term:put(?SNAPSHOT_BUDGET_KEY, Value),
    try F()
    after
        persistent_term:put(?SNAPSHOT_BUDGET_KEY, Saved)
    end.

%% Restore validates each stored value against the same allowlist capture uses.
%% An external reference is a bare host term; a forged image that slipped one
%% into a global would hand it to a host function as if the host had made it.
an_injected_external_reference_is_refused(_Config) ->
    ?assertMatch({error, #{kind := snapshot_invalid_value}},
                 restore_parts(#{globals => [{extern, evil}]}, module_with(1))).

%% A funcref names a function by index; restore writes it straight into a table,
%% so an index past the module's functions is refused rather than reaching an
%% out-of-range `element/2`.
an_out_of_range_funcref_is_refused(_Config) ->
    ?assertMatch({error, #{kind := snapshot_invalid_value}},
                 restore_parts(#{tables => [[{funcref, self, 99}]]},
                               module_with(1))).

%% Restore re-applies the module eligibility capture enforces. An imported
%% memory, table or global is caller-owned; restoring into it would overwrite
%% or alias somebody else's state.
an_image_for_a_module_with_imported_state_is_refused(_Config) ->
    Imported = (module_with(1))#module{
                 imports = [#import{module = ~"env", name = ~"g",
                                    desc = {global,
                                            #globaltype{valtype = i32,
                                                        mut = const}}}]},
    ?assertMatch({error, #{kind := imported_state_not_snapshottable}},
                 restore_parts(#{}, Imported)).

%% A shared memory has no single owner an image can speak for.
an_image_with_a_shared_memory_is_refused(_Config) ->
    Shared = (module_with(1))#module{
               mems = [#memtype{limits = #limits{min = 1, shared = true}}]},
    ?assertMatch({error, #{kind := shared_memory_not_snapshottable}},
                 restore_parts(#{}, Shared)).

%% Build a well-formed parts map with one field overridden, and run it through
%% the off-disk validation for a given module.
restore_parts(Overrides, M) ->
    Hash = <<0:256>>,
    Parts = maps:merge(#{hash => Hash, version => ~"1", key => ~"k",
                         shape => undefined, globals => [], tables => [],
                         mems => [], dropped => {[], []}, hooks => #{}},
                       Overrides),
    wasm_snapshot:from_parts(Parts, {wasm_module, Hash}, M).

module_with(NFuncs) ->
    #module{identity = {sha256, <<0:256>>},
            funcs = [#func{type = 0} || _ <- lists:seq(1, NFuncs)]}.

written(Config, Path) ->
    Handle = fixture(reactor),
    _ = written_to(Config, Path),
    Handle.

written_to(_Config, Path) ->
    Handle = fixture(reactor),
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{version => ~"v1",
                                        compatibility_key => ~"k"}),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    ok = wasm:destroy(Init),
    Path.

%%% ------------------------------------------------ the directory is bounded ---

with_store(Dir, Max, F) ->
    ok = filelib:ensure_path(Dir),
    application:set_env(wasm, snapshot_dir, Dir),
    application:set_env(wasm, max_snapshot_dir_bytes, Max),
    try F()
    after
        application:unset_env(wasm, snapshot_dir),
        application:unset_env(wasm, max_snapshot_dir_bytes)
    end.

images(Dir) -> filelib:wildcard(filename:join(Dir, "*.img")).

total(Dir) -> lists:sum([filelib:file_size(F) || F <- images(Dir)]).

%% Files an image under a key of its own, the way a worker does for a distinct
%% module or adapter version.
file_one(Handle, Key) ->
    Init = init(Handle, #{}),
    {ok, Image} = wasm:snapshot(Init, #{version => ~"v1",
                                        compatibility_key => Key}),
    ok = wasm_snapshot_store:store(
           wasm_snapshot_store:key(hash_of(Handle), ~"v1", Key,
                                   wasm_snapshot_file:image_abi()),
           Image, undefined),
    ok = wasm:release(Image),
    ok = wasm:destroy(Init).

hash_of({wasm_module, Hash}) -> Hash.

%% **The disk-filling bug, as an assertion.** A worker files an image per
%% module, version and compatibility key, and before this nothing ever removed
%% one: the directory grew with the deploy count until the disk was full.
a_filed_image_directory_stays_under_its_cap(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "capped"),
    Handle = fixture(reactor),
    %% Room for one image and not two. The images are a few hundred bytes, so
    %% the cap is too -- which is the whole reason it is a setting rather than
    %% a constant nothing can reach.
    One = filed_size(Config, Handle),
    with_store(Dir, One + (One div 2), fun() ->
        [file_one(Handle, K) || K <- [~"a", ~"b", ~"c", ~"d"]],
        ?assert(total(Dir) =< One + (One div 2)),
        ?assertMatch([_], images(Dir)),
        %% And what survived is still usable, not a truncated remnant.
        [Survivor] = images(Dir),
        ?assertMatch({ok, _}, wasm:load_snapshot(Survivor, Handle))
    end).

%% How big one image is on disk, measured rather than guessed, so the cap in
%% the case above tracks the format instead of a number that rots.
filed_size(Config, Handle) ->
    Dir = filename:join(?config(priv_dir, Config), "sizing"),
    with_store(Dir, 1 bsl 40, fun() ->
        file_one(Handle, ~"sizing"),
        [F] = images(Dir),
        filelib:file_size(F)
    end).

%% `wasm:save_snapshot/2` writes `<hex>.img.<n>.tmp` and renames. A node that
%% dies in between leaves one, and `purge/0` globbed `*.img`, so it did not.
a_purge_takes_the_half_written_files_too(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "purged"),
    Handle = fixture(reactor),
    with_store(Dir, 1 bsl 40, fun() ->
        file_one(Handle, ~"p"),
        [Img] = images(Dir),
        Tmp = Img ++ ".999.tmp",
        ok = file:write_file(Tmp, ~"half written"),
        ok = wasm_snapshot_store:purge(),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*")))
    end).

%%% ---------------------------------------------------------- the setting ---
%%
%% Every case above sets the cap low and watches eviction happen, and **all of
%% them would pass against a hardcoded cap of the same size**. These are what
%% say the setting is read, what an absent or unusable one does, and *when* a
%% change takes effect.

with_cap(Max, F) ->
    application:set_env(wasm, max_snapshot_dir_bytes, Max),
    try F() after application:unset_env(wasm, max_snapshot_dir_bytes) end.

an_unset_cap_is_the_default(_Config) ->
    ok = application:unset_env(wasm, max_snapshot_dir_bytes),
    %% The resolved number, not "a small directory survived", which would pass
    %% with no cap at all.
    ?assertEqual(512 * 1024 * 1024, wasm_snapshot_store:max_bytes()).

%% Two values, because one cannot tell a setting being read from a constant
%% that happens to match it.
a_set_cap_is_the_one_reported(_Config) ->
    with_cap(4096, fun() -> ?assertEqual(4096, wasm_snapshot_store:max_bytes()) end),
    with_cap(99, fun() -> ?assertEqual(99, wasm_snapshot_store:max_bytes()) end).

%% Taken literally, a cap of `0` or `-1` deletes every image on the next store,
%% and a float reaches `lists:sum/1` comparisons that silently do the wrong
%% thing. The same treatment `compile_max_heap_words` already gets.
a_cap_that_is_not_a_size_falls_back(_Config) ->
    Default = 512 * 1024 * 1024,
    [with_cap(Bad, fun() ->
         ?assertEqual(Default, wasm_snapshot_store:max_bytes())
     end) || Bad <- [-1, 1.5, unlimited, ~"512"]].

%% Read on every store, so a change is in force from the next one. This pins
%% both that the value is read and when.
a_raised_cap_takes_effect_at_the_next_store(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "raised"),
    Handle = fixture(reactor),
    One = filed_size(Config, Handle),
    with_store(Dir, One + (One div 2), fun() ->
        [file_one(Handle, K) || K <- [~"a", ~"b"]],
        ?assertMatch([_], images(Dir)),
        %% Room for three now, and the next store is what notices.
        application:set_env(wasm, max_snapshot_dir_bytes, One * 3 + 100),
        [file_one(Handle, K) || K <- [~"c", ~"d"]],
        ?assertEqual(3, length(images(Dir)))
    end).

%% The surprising half of "eviction happens on a store": lowering the setting
%% does nothing until something is written, and `purge/0` is what shrinks a
%% directory now. Worth an assertion rather than only a sentence in the guide.
a_lowered_cap_does_not_shrink_the_directory(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "lowered"),
    Handle = fixture(reactor),
    One = filed_size(Config, Handle),
    with_store(Dir, One * 4, fun() ->
        [file_one(Handle, K) || K <- [~"a", ~"b", ~"c"]],
        ?assertEqual(3, length(images(Dir))),
        application:set_env(wasm, max_snapshot_dir_bytes, One),
        %% No store, so nothing moved.
        ?assertEqual(3, length(images(Dir))),
        %% And this is the way to shrink one now.
        ok = wasm_snapshot_store:purge(),
        ?assertEqual([], images(Dir))
    end).

%% An image is decoded with `binary_to_existing_atom/2`, which is right: a file
%% must not be able to mint an atom. But "existing" is a property of the
%% emulator at that instant, and Erlang loads modules lazily, so before
%% `wasm_snapshot_file:own_atoms/0' existed the answer depended on whether some
%% unrelated module carrying the same literal happened to have been loaded.
%%
%% It cost a hundred and four seconds a time: a CPython image holds `funcref',
%% a freshly started node did not have that atom, the image was refused,
%% `wasm_snapshot_store:lookup/2' turned the refusal into a miss as it must,
%% and the worker captured a snapshot it already had on disk.
%%
%% **This needs a node of its own.** In this one everything is loaded long
%% before the case runs, so the property is unfalsifiable here: the assertion
%% would pass whether or not the fix exists. A peer starts with nothing loaded,
%% which is the only place the question can be asked.
every_atom_an_image_holds_exists_once_the_decoder_is_loaded(_Config) ->
    %% `standard_io' rather than a named node: the suite runs as
    %% `nonode@nohost' and a named peer wants distribution started, which this
    %% case has no use for.
    {ok, Peer, _} =
        peer:start_link(#{connection => standard_io,
                          args => ["-pa" | code:get_path()]}),
    try
        %% Loading the decoder is the whole intervention. Nothing in that node
        %% has decoded, validated or instantiated anything.
        ?assertEqual({module, wasm_snapshot_file},
                     peer:call(Peer, code, ensure_loaded, [wasm_snapshot_file])),
        %% **Written out here, not read from `own_atoms/0`.** Taking the list
        %% from the module under test would make this vacuous: dropping a name
        %% from the list would drop it from the test in the same motion, and
        %% the case would go on passing. That is exactly what happened the
        %% first time this was falsified.
        Expected = [funcref, null, i31, nan, infinity, neg_infinity],
        ?assertEqual(lists:sort(Expected),
                     lists:sort(wasm_snapshot_file:own_atoms())),
        [?assertEqual(A, peer:call(Peer, erlang, binary_to_existing_atom,
                                   [atom_to_binary(A, utf8), utf8]))
         || A <- Expected]
    after
        peer:stop(Peer)
    end.
