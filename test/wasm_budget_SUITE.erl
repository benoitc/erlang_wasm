-module(wasm_budget_SUITE).
-moduledoc """
Limits that a host function calling back in used to hand back.

Fuel, depth and the host-call count all belong to the invocation the embedder
started, not to each entry into the interpreter. A guest that recurses by going
out through an import and back in is doing the same work as one that recursed
directly, and every limit has to see it that way.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([an_import_called_in_a_loop_is_stopped/1,
         calling_back_in_does_not_refill_the_fuel/1,
         calling_back_in_does_not_reset_the_host_call_count/1,
         calling_back_in_does_not_reset_the_depth/1,
         a_plain_call_still_gets_its_own_budget/1,
         over_declared_pages_are_refused/1,
         growth_past_the_ceiling_returns_minus_one/1,
         an_imported_memory_counts_against_the_ceiling/1,
         the_strictest_holder_bounds_a_shared_memory/1,
         two_slots_on_one_memory_count_once/1,
         a_limit_that_is_not_a_number_is_refused/1]).

all() ->
    [an_import_called_in_a_loop_is_stopped,
     calling_back_in_does_not_refill_the_fuel,
     calling_back_in_does_not_reset_the_host_call_count,
     calling_back_in_does_not_reset_the_depth,
     a_plain_call_still_gets_its_own_budget,
     over_declared_pages_are_refused,
     growth_past_the_ceiling_returns_minus_one,
     an_imported_memory_counts_against_the_ceiling,
     the_strictest_holder_bounds_a_shared_memory,
     two_slots_on_one_memory_count_once,
     a_limit_that_is_not_a_number_is_refused].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Parsed} = wasm_wat:module(source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

source() -> ~"""
(module
  (import "e" "h" (func $h))
  (import "e" "reenter" (func $reenter))
  (func (export "loop_host") (param $n i32)
    (local $i i32)
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (call $h)
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))
  (func (export "spin") (param $n i32)
    (local $i i32)
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))
  (func (export "bounce") (param $n i32)
    (local $i i32)
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (call $reenter)
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))
  (func (export "down") (call $reenter)))
""".

%%% ----------------------------------------------------------------- cases ---

%% A host call burns no fuel by construction: what it costs is the host's time,
%% not the guest's. `max_host_calls` is the limit that bounds it, and it was
%% listed in `wasm_limits` and enforced nowhere, so a module looping over an
%% import did unbounded work for free.
an_import_called_in_a_loop_is_stopped(Config) ->
    I = instance(Config, fun(_C, []) -> {ok, []} end),
    ?assertMatch({error, #{class := exhaustion, kind := host_call_limit}},
                 wasm:call(I, ~"loop_host", [10000],
                           #{max_host_calls => 100, fuel => infinity})),
    ok = wasm:destroy(I).

%% Each entry into the interpreter built a fresh budget, so a guest that
%% bounced out through an import and back in was handed its whole fuel
%% allowance again every time round.
calling_back_in_does_not_refill_the_fuel(Config) ->
    Self = self(),
    I = instance(Config, fun(_C, []) ->
                            Inst = get(inst),
                            Self ! spun,
                            case wasm:call(Inst, ~"spin", [2000]) of
                                {ok, _} -> {ok, []};
                                {error, E} -> {trap, E}
                            end
                        end),
    put(inst, I),
    %% Twenty bounces of two thousand back edges each cannot fit in ten
    %% thousand fuel. With a budget per entry, each one could.
    ?assertMatch({error, _},
                 wasm:call(I, ~"bounce", [20], #{fuel => 10000})),
    ?assert(drain(spun) < 20),
    ok = wasm:destroy(I).

calling_back_in_does_not_reset_the_host_call_count(Config) ->
    Self = self(),
    I = instance(Config, fun(_C, []) ->
                            Inst = get(inst),
                            Self ! called,
                            %% Ten more host calls, from inside a host call.
                            _ = wasm:call(Inst, ~"loop_host", [10]),
                            {ok, []}
                        end),
    put(inst, I),
    ?assertMatch({error, #{class := exhaustion, kind := host_call_limit}},
                 wasm:call(I, ~"bounce", [100],
                           #{max_host_calls => 50, fuel => infinity})),
    %% The nested calls counted, so far fewer than fifty bounces happened.
    ?assert(drain(called) < 50),
    ok = wasm:destroy(I).

%% Depth is the same story. Going out through an import and back in put the
%% guest one frame from the top again, so `max_depth` bounded one leg of a
%% recursion rather than the recursion.
calling_back_in_does_not_reset_the_depth(Config) ->
    Self = self(),
    I = instance(Config, fun(_C, []) ->
                            Inst = get(inst),
                            Self ! deeper,
                            case wasm:call(Inst, ~"down", []) of
                                {ok, _} -> {ok, []};
                                {error, E} -> {trap, E}
                            end
                        end),
    put(inst, I),
    ?assertMatch({error, _},
                 wasm:call(I, ~"down", [],
                           #{max_depth => 8, fuel => infinity,
                             max_host_calls => 500})),
    Levels = drain(deeper),
    ?assert(Levels =< 16),
    ok = wasm:destroy(I).

%% And the budget really is per outermost invocation: a second call starts
%% again, or one exhausted call would poison the instance.
a_plain_call_still_gets_its_own_budget(Config) ->
    I = instance(Config, fun(_C, []) -> {ok, []} end),
    Opts = #{max_host_calls => 100, fuel => infinity},
    ?assertMatch({error, #{kind := host_call_limit}},
                 wasm:call(I, ~"loop_host", [10000], Opts)),
    ?assertEqual({ok, []}, wasm:call(I, ~"loop_host", [10], Opts)),
    ?assertEqual({ok, []}, wasm:call(I, ~"loop_host", [10], Opts)),
    ok = wasm:destroy(I).

%%% ---------------------------------------------------------- memory pages ---

%% `max_memory_pages` was documented as a per-instance ceiling in two places and
%% enforced in neither. A module declaring three hundred pages instantiated
%% happily under a limit of two hundred and fifty-six.
over_declared_pages_are_refused(_Config) ->
    Mod = compile(~"(module (memory 300))"),
    ?assertMatch({error, #{class := exhaustion, kind := memory_limit}},
                 wasm:instantiate(Mod, #{}, #{max_memory_pages => 256})),
    %% And under a ceiling that fits, it instantiates.
    {ok, I} = wasm:instantiate(Mod, #{}, #{max_memory_pages => 512}),
    ok = wasm:destroy(I).

growth_past_the_ceiling_returns_minus_one(_Config) ->
    Mod = compile(~"(module (memory 1 100)
                      (func (export \"g\") (param i32) (result i32)
                        (memory.grow (local.get 0))))"),
    {ok, I} = wasm:instantiate(Mod, #{}, #{max_memory_pages => 8}),
    ?assertEqual({ok, [1]}, wasm:call(I, ~"g", [4])),
    %% Five held, four more fits, five more does not.
    ?assertEqual({ok, [-1]}, wasm:call(I, ~"g", [5])),
    ?assertEqual({ok, [5]}, wasm:call(I, ~"g", [3])),
    ok = wasm:destroy(I).

%% The check cannot live where memories are created, because an imported one is
%% never created by the instance that imports it. This case trips only there.
an_imported_memory_counts_against_the_ceiling(_Config) ->
    {ok, Mem} = wasm_memory:new(64, 64),
    Mod = compile(~"(module (import \"e\" \"m\" (memory 64 64)))"),
    ?assertMatch({error, #{class := exhaustion, kind := memory_limit}},
                 wasm:instantiate(Mod, #{{~"e", ~"m"} => Mem},
                                  #{max_memory_pages => 32})),
    {ok, I} = wasm:instantiate(Mod, #{{~"e", ~"m"} => Mem},
                               #{max_memory_pages => 128}),
    ok = wasm:destroy(I),
    ok = wasm_memory:free(Mem).

%% Two instances, one memory, different ceilings. Growing it has to satisfy
%% both, or the generous one grows past what the strict one was promised.
the_strictest_holder_bounds_a_shared_memory(_Config) ->
    {ok, Mem} = wasm_memory:new(1, 100),
    Mod = compile(~"(module (import \"e\" \"m\" (memory 1 100))
                      (func (export \"g\") (param i32) (result i32)
                        (memory.grow (local.get 0))))"),
    Imports = #{{~"e", ~"m"} => Mem},
    {ok, Generous} = wasm:instantiate(Mod, Imports, #{max_memory_pages => 64}),
    {ok, Strict} = wasm:instantiate(Mod, Imports, #{max_memory_pages => 4}),
    %% Three more fits under both.
    ?assertEqual({ok, [1]}, wasm:call(Generous, ~"g", [3])),
    %% One more does not fit under the strict one, even asked of the other.
    ?assertEqual({ok, [-1]}, wasm:call(Generous, ~"g", [1])),
    %% Once the strict holder lets go, the generous one may grow again.
    ok = wasm:destroy(Strict),
    ?assertEqual({ok, [4]}, wasm:call(Generous, ~"g", [1])),
    ok = wasm:destroy(Generous),
    ok = wasm_memory:free(Mem).

%% One memory, two import slots, one holder. Counting slots would charge the
%% ceiling twice for a memory the instance holds once.
two_slots_on_one_memory_count_once(_Config) ->
    {ok, Mem} = wasm_memory:new(6, 8),
    Mod = compile(~"(module (import \"e\" \"a\" (memory 6 8))
                            (import \"e\" \"b\" (memory 6 8)))"),
    {ok, I} = wasm:instantiate(Mod, #{{~"e", ~"a"} => Mem,
                                      {~"e", ~"b"} => Mem},
                               #{max_memory_pages => 8}),
    ok = wasm:destroy(I),
    ok = wasm_memory:free(Mem).

%%% --------------------------------------------------------------- helpers ---

compile(Wat) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, Mod} = wasm_validate:module(P),
    Mod.

instance(Config, Reenter) ->
    Imports = #{{~"e", ~"h"} => fun(_C, []) -> {ok, []} end,
                {~"e", ~"reenter"} => Reenter},
    {ok, I} = wasm:instantiate(?config(mod, Config), Imports),
    I.

drain(Tag) -> drain(Tag, 0).
drain(Tag, N) ->
    receive Tag -> drain(Tag, N + 1)
    after 0 -> N
    end.

%% A limit that cannot mean what it says is refused, not ignored.
%%
%% `wasm_limits:validate/1` could always answer this and nothing called it, so a
%% bad value was simply not enforced. `#{max_depth => lots}` is the sharp one
%% and it failed *open*: the guard is `Depth >= MaxDepth`, every integer sorts
%% before every atom in Erlang term order, so the test was never true and a
%% guest recursed a million frames under a ceiling the embedder believed it had
%% set. Every other bad value already failed closed, which is what made this one
%% easy to miss.
a_limit_that_is_not_a_number_is_refused(_Config) ->
    Mod = recursive(),
    Bad = [{max_depth, lots}, {fuel, lots}, {max_memory_pages, -1},
           {max_depth, 0}, {max_heap_words, 0}],
    [?assertMatch({error, #{class := link, kind := invalid_limits,
                            ctx := #{keys := [K]}}},
                  wasm:instantiate(Mod, #{}, #{K => V}))
     || {K, V} <- Bad],
    %% And per call, where a limits map also lands.
    {ok, Inst} = wasm:instantiate(Mod, #{}, #{}),
    ?assertMatch({error, #{class := link, kind := invalid_limits}},
                 wasm:call(Inst, ~"r", [10], #{max_depth => lots})),
    %% The limit that used to vanish now bites, and a valid one still works.
    ?assertMatch({error, #{class := exhaustion, kind := call_stack_exhausted}},
                 wasm:call(Inst, ~"r", [100000], #{max_depth => 64})),
    ?assertEqual({ok, [0]}, wasm:call(Inst, ~"r", [10])),
    ok = wasm:destroy(Inst).

recursive() ->
    {ok, M} = wasm:compile({wat, ~"""
    (module
      (func $r (export "r") (param i32) (result i32)
        (if (result i32) (i32.eqz (local.get 0))
          (then (i32.const 0))
          (else (call $r (i32.sub (local.get 0) (i32.const 1)))))))
    """}),
    M.
