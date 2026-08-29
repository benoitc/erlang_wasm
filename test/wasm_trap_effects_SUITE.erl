-module(wasm_trap_effects_SUITE).
-moduledoc """
What a trapped computation leaves behind.

A trap ends the computation; it does not undo it. The store keeps every write
made before the trap, which the specification requires and which `linking.wast`
asserts for an imported memory and an imported table. Writes that go straight
to a shared structure were always kept. The ones threaded through the
interpreter's own state were discarded with the stack the trap unwound.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([a_global_written_before_a_trap_survives/1,
         a_global_written_before_a_host_call_survives_a_trap/1,
         a_global_written_around_re_entry_survives_a_trap/1,
         a_private_memory_keeps_the_size_it_grew_to/1,
         a_dropped_segment_stays_dropped/1]).

all() ->
    [a_global_written_before_a_trap_survives,
     a_global_written_before_a_host_call_survives_a_trap,
     a_global_written_around_re_entry_survives_a_trap,
     a_private_memory_keeps_the_size_it_grew_to,
     a_dropped_segment_stays_dropped].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Parsed} = wasm_wat:module(source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

%% The memory is deliberately not exported. An exported one publishes its size
%% and would keep it however the call ended, which is the case that already
%% worked and not the one under test.
source() -> ~"""
(module
  (import "e" "h" (func $h))
  (import "e" "reenter" (func $reenter))
  (global $g (mut i32) (i32.const 0))
  (memory 1 8)
  (data $d "hello")
  (func (export "set_then_trap") (param i32)
    (global.set $g (local.get 0))
    (unreachable))
  (func (export "set_host_trap") (param i32)
    (global.set $g (local.get 0))
    (call $h)
    (unreachable))
  (func (export "set_reenter_trap") (param i32) (param i32)
    (global.set $g (local.get 0))
    (call $reenter)
    (global.set $g (local.get 1))
    (unreachable))
  (func (export "get_g") (result i32) (global.get $g))
  (func (export "set_g") (param i32) (global.set $g (local.get 0)))
  (func (export "grow_then_trap")
    (drop (memory.grow (i32.const 3)))
    (unreachable))
  (func (export "size") (result i32) (memory.size))
  (func (export "drop_then_trap")
    (data.drop $d)
    (unreachable))
  (func (export "init") (param i32)
    (memory.init $d (local.get 0) (i32.const 0) (i32.const 5))))
""".

%%% ----------------------------------------------------------------- cases ---

a_global_written_before_a_trap_survives(Config) ->
    I = instance(Config),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"get_g", [])),
    ?assertMatch({error, #{class := trap, kind := unreachable}},
                 wasm:call(I, ~"set_then_trap", [11])),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"get_g", [])),
    ok = wasm:destroy(I).

%% Publishing around a host call and adopting afterwards already existed, for
%% re-entrancy. What did not was any of it surviving the trap that follows.
a_global_written_before_a_host_call_survives_a_trap(Config) ->
    I = instance(Config),
    ?assertMatch({error, #{class := trap}}, wasm:call(I, ~"set_host_trap", [22])),
    ?assertEqual({ok, [22]}, wasm:call(I, ~"get_g", [])),
    ok = wasm:destroy(I).

%% Three writes: the outer one, a nested one that must see it, and an outer one
%% after the nested call returns. The last is the one the trap must not lose.
a_global_written_around_re_entry_survives_a_trap(Config) ->
    I = instance(Config),
    ?assertMatch({error, #{class := trap}},
                 wasm:call(I, ~"set_reenter_trap", [33, 44])),
    ?assertEqual({ok, [44]}, wasm:call(I, ~"get_g", [])),
    %% And the nested call did see the outer's write rather than a stale one.
    receive {saw, Seen} -> ?assertEqual(33, Seen)
    after 0 -> ct:fail(no_reenter)
    end,
    ok = wasm:destroy(I).

%% A private memory keeps its size in the handle, so growth is a store mutation
%% like any other. `memory.grow` answered the old size, the guest believed it
%% had the pages, and the trap put the handle back the way it was.
a_private_memory_keeps_the_size_it_grew_to(Config) ->
    I = instance(Config),
    ?assertEqual({ok, [1]}, wasm:call(I, ~"size", [])),
    ?assertMatch({error, #{class := trap}}, wasm:call(I, ~"grow_then_trap", [])),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"size", [])),
    ok = wasm:destroy(I).

%% Dropping a passive segment is a store mutation too, and undoing it would
%% make a `memory.init` that must trap succeed instead.
a_dropped_segment_stays_dropped(Config) ->
    I = instance(Config),
    ?assertEqual({ok, []}, wasm:call(I, ~"init", [0])),
    ?assertMatch({error, #{class := trap}}, wasm:call(I, ~"drop_then_trap", [])),
    ?assertMatch({error, #{class := trap,
                           kind := out_of_bounds_memory_access}},
                 wasm:call(I, ~"init", [0])),
    ok = wasm:destroy(I).

%%% --------------------------------------------------------------- helpers ---

instance(Config) ->
    Self = self(),
    Ref = make_ref(),
    put(Ref, undefined),
    Imports = #{{~"e", ~"h"} => fun(_C, []) -> {ok, []} end,
                {~"e", ~"reenter"} =>
                    fun(_C, []) ->
                        Inst = get(Ref),
                        {ok, [Seen]} = wasm:call(Inst, ~"get_g", []),
                        Self ! {saw, Seen},
                        {ok, []} = wasm:call(Inst, ~"set_g", [99]),
                        {ok, []}
                    end},
    {ok, I} = wasm:instantiate(?config(mod, Config), Imports),
    put(Ref, I),
    I.
