%% @doc Exception handling: the rules that are easy to get wrong.
%%
%% Duplicates coverage the specification fixtures give, for the same reason the
%% other unit suites do: the fixtures are generated rather than committed, so a
%% fresh clone skips them.
%%
%% The case that matters most here is `a_trap_is_not_catchable'. Traps and
%% exceptions look alike from a distance and the runtime deliberately keeps them
%% on separate paths, so a change that merged them would still pass every other
%% test in this file.
-module(wasm_exception_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).

all() ->
    [a_throw_is_caught_by_the_enclosing_handler,
     catch_all_catches_anything,
     an_uncaught_throw_is_a_structured_error,
     a_trap_is_not_catchable,
     a_throw_unwinds_through_a_call,
     tags_are_identities_not_types].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% The handler nearest the throw wins, and it receives the tag's parameters.
a_throw_is_caught_by_the_enclosing_handler(_Config) ->
    {ok, Inst} = instantiate(throw_module()),
    ?assertMatch({ok, [42]}, wasm:call(Inst, ~"caught", [])),
    ok = wasm:destroy(Inst).

%% `catch_all' takes any exception and receives nothing, so it can sit after a
%% tag-specific handler as a fallback.
catch_all_catches_anything(_Config) ->
    {ok, Inst} = instantiate(throw_module()),
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"caught_all", [])),
    ok = wasm:destroy(Inst).

%% An exception that escapes the outermost invocation is the embedder's to see,
%% and the instance stays usable afterwards like any other aborted call.
an_uncaught_throw_is_a_structured_error(_Config) ->
    {ok, Inst} = instantiate(throw_module()),
    ?assertMatch({error, #{class := trap, kind := uncaught_exception,
                           ctx := #{values := [42]}}},
                 wasm:call(Inst, ~"uncaught", [])),
    ?assertMatch({ok, [42]}, wasm:call(Inst, ~"caught", [])),
    ok = wasm:destroy(Inst).

%% A trap is not an exception and `catch_all' must not catch it.
%%
%% The two are kept on separate paths deliberately: an exception unwinds through
%% the interpreter's own control frames, a trap stays a `wasm_error' throw and
%% passes straight through every handler. Merging them would let a module
%% swallow a division by zero or an out-of-bounds access.
a_trap_is_not_catchable(_Config) ->
    {ok, Inst} = instantiate(throw_module()),
    ?assertMatch({error, #{class := trap, kind := unreachable}},
                 wasm:call(Inst, ~"trap_inside_try", [])),
    ?assertMatch({error, #{class := trap, kind := integer_divide_by_zero}},
                 wasm:call(Inst, ~"divide_inside_try", [])),
    ok = wasm:destroy(Inst).

%% A throw unwinds out of nested calls until it finds a handler, which is what
%% makes exception handling worth having at all.
a_throw_unwinds_through_a_call(_Config) ->
    {ok, Inst} = instantiate(throw_module()),
    ?assertMatch({ok, [42]}, wasm:call(Inst, ~"caught_through_call", [])),
    ok = wasm:destroy(Inst).

%% Two tags with identical types are still different tags: a `catch' naming one
%% must not catch the other. Tags are identities, so a structural comparison
%% would wrongly conflate them.
tags_are_identities_not_types(_Config) ->
    {ok, Inst} = instantiate(two_tag_module()),
    %% Thrown with tag 0, caught by the handler naming tag 0.
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"matching", [])),
    %% Thrown with tag 1, whose handler names tag 0: not caught.
    ?assertMatch({error, #{class := trap, kind := uncaught_exception}},
                 wasm:call(Inst, ~"mismatched", [])),
    ok = wasm:destroy(Inst).

%%% --------------------------------------------------------- module builder ---

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

%% Type 0: () -> ()          the tag's own type, carrying one i32
%% Type 1: () -> (i32)       the exported functions
%% Type 2: (i32) -> ()       the tag type
-define(TRY_TABLE, 16#1F).
-define(THROW, 16#08).

throw_module() ->
    Tag = 0,
    %% A handler's label is resolved *outside* the `try_table', so each of
    %% these wraps it in a block and the handler branches to that block's end.
    %% The block's result type is therefore what the handler delivers.
    %%
    %% ```
    %% (block $h (result i32)
    %%   (try_table (catch $t $h) (throw $t (i32.const 42)))
    %%   (i32.const 0))            ;; only if nothing was thrown
    %% ```
    Caught = <<16#02, ?I32,                      % block (result i32)
                 ?TRY_TABLE, 16#40,              %   try_table
                 1, 16#00, Tag, 0,               %     catch $t -> label 0
                 16#41, 42, ?THROW, Tag,
                 16#0B,                          %   end try_table
                 16#41, 0,                       %   not reached
               16#0B,                            % end block
               16#0B>>,
    %% `catch_all' delivers nothing, so its label must accept nothing: the
    %% block has no result and the value is produced after it.
    CaughtAll = <<16#02, 16#40,
                    ?TRY_TABLE, 16#40,
                    1, 16#02, 0,                 %     catch_all -> label 0
                    16#41, 42, ?THROW, Tag,
                    16#0B,
                  16#0B,
                  16#41, 7,
                  16#0B>>,
    Uncaught = <<16#41, 42, ?THROW, Tag, 16#0B>>,
    %% A trap inside a `try_table' with a `catch_all' must still escape.
    TrapInside = <<16#02, 16#40,
                     ?TRY_TABLE, 16#40, 1, 16#02, 0,
                     16#00,                      % unreachable
                     16#0B,
                   16#0B,
                   16#41, 0, 16#0B>>,
    DivInside = <<16#02, 16#40,
                    ?TRY_TABLE, 16#40, 1, 16#02, 0,
                    16#41, 1, 16#41, 0, 16#6D, 16#1A,   % 1 / 0, drop
                    16#0B,
                  16#0B,
                  16#41, 0, 16#0B>>,
    %% The throw happens one call deeper than the handler.
    ThroughCall = <<16#02, ?I32,
                      ?TRY_TABLE, 16#40, 1, 16#00, Tag, 0,
                      16#10, 6,                  %   call $thrower
                      16#0B,
                      16#41, 0,
                    16#0B,
                    16#0B>>,
    Thrower = <<16#41, 42, ?THROW, Tag, 16#0B>>,
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}, {[], [?I32]}, {[?I32], []}]),
       wasm_asm:func_section([1, 1, 1, 1, 1, 1, 0]),
       tag_section([2]),
       wasm_asm:export_section([{~"caught", 0, 0}, {~"caught_all", 0, 1},
                                {~"uncaught", 0, 2},
                                {~"trap_inside_try", 0, 3},
                                {~"divide_inside_try", 0, 4},
                                {~"caught_through_call", 0, 5}]),
       wasm_asm:code_section([Caught, CaughtAll, Uncaught, TrapInside,
                              DivInside, ThroughCall, Thrower])]).

%% Two tags of identical type, to show the match is on identity.
two_tag_module() ->
    Body = fun(ThrownTag) ->
                   <<16#02, ?I32,
                       ?TRY_TABLE, 16#40,
                       1, 16#00, 0, 0,           %   catch tag 0 -> label 0
                       16#41, 1, ?THROW, ThrownTag,
                       16#0B,
                       16#41, 0,
                     16#0B,
                     16#0B>>
           end,
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}, {[], [?I32]}, {[?I32], []}]),
       wasm_asm:func_section([1, 1]),
       tag_section([2, 2]),
       wasm_asm:export_section([{~"matching", 0, 0}, {~"mismatched", 0, 1}]),
       wasm_asm:code_section([Body(0), Body(1)])]).

%% Section 13. The leading 0x00 on each entry is the tag's attribute byte.
tag_section(TypeIdxs) ->
    wasm_asm:section(13, [wasm_asm:uleb(length(TypeIdxs)) |
                          [[16#00, wasm_asm:uleb(T)] || T <- TypeIdxs]]).
