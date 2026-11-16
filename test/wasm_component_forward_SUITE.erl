-module(wasm_component_forward_SUITE).
-moduledoc """
`stream.forward` and `future.forward`, through the `asyncforward` fixture.

No tool writes these two built-ins yet, so the fixture is written with
placeholders and its opcodes rewritten (see its source). Forwarding hands
everything that reaches a readable end on to the reader of a writable end,
and the end of the one ends the other; both handles leave the guest.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_forwarded_stream_carries_every_value_and_its_end/1,
         a_forwarded_future_carries_its_value/1,
         forwarding_into_its_own_end_drops_both/1,
         an_end_being_read_cannot_be_forwarded/1,
         an_end_in_a_waitable_set_cannot_be_forwarded/1]).

all() ->
    [a_forwarded_stream_carries_every_value_and_its_end,
     a_forwarded_future_carries_its_value,
     forwarding_into_its_own_end_drops_both,
     an_end_being_read_cannot_be_forwarded,
     an_end_in_a_waitable_set_cannot_be_forwarded].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(
                  filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                                 "fixtures", "component",
                                 "asyncforward.component.wasm"])),
    [{bin, Bin} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(bin, Config)),
    [{inst, Inst} | Config].

end_per_testcase(_, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%%% --------------------------------------------------------------- cases ---

%% Fail-first, for each case: both built-ins were decoded but trapped as
%% `unsupported_async_builtin'.

a_forwarded_stream_carries_every_value_and_its_end(Config) ->
    Values = lists:seq(1, 3000),
    ?assertEqual({ok, Values},
                 call(Config, ~"pipe", {[{stream, u32}], {stream, u32}}, [Values])).

a_forwarded_future_carries_its_value(Config) ->
    ?assertEqual({ok, 41},
                 call(Config, ~"pipe-future", {[{future, u32}], {future, u32}}, [41])).

%% Forwarding a stream into its own writable end drops both ends, so the
%% guest dropping the readable end again names an end that is gone.
forwarding_into_its_own_end_drops_both(Config) ->
    traps(unknown_waitable, call(Config, ~"loop", {[], u32}, [])).

an_end_being_read_cannot_be_forwarded(Config) ->
    traps(forward_end_not_idle, call(Config, ~"busy", {[], u32}, [])).

an_end_in_a_waitable_set_cannot_be_forwarded(Config) ->
    traps(forward_end_in_waitable_set, call(Config, ~"in-set", {[], u32}, [])).

%%% ------------------------------------------------------------- helpers ---

call(Config, Export, Sig, Args) ->
    wasm_component:call_async(?config(inst, Config), Export, Sig, Args).

traps(Reason, Result) ->
    ?assertMatch({error, #{class := trap, kind := host_error,
                           ctx := #{reason := Reason}}}, Result).
