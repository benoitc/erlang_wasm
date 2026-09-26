-module(wasm_component_async_SUITE).
-moduledoc """
Typed `future<T>` and `stream<T>` over the async Canonical ABI, against a real guest.

The fixture (`scripts/build-component-fixture.sh`, `asyncval`) is a wit-bindgen
async guest exporting `read-future: async func(future<u32>) -> u32` and
`sum-stream: async func(stream<u8>) -> u32`. Each case hands the guest the readable
end of a pre-filled future or stream through `wasm_component:call_async/4`; the guest
reads it and returns a value, so `future.read`/`stream.read` (copying the element
into guest memory and reporting the Canonical ABI completion code) are exercised
end to end. The reads complete at once, so the callee runs to `task.return` without
suspending.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [reads_a_future, reads_a_zero_future, sums_a_stream,
     sums_an_empty_stream, sums_a_long_stream].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% A bare instance is scoped to the process that created it, and the test case runs
%% in this process, so instantiate per case.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config)),
    [{inst, Inst} | Config].

end_per_testcase(_Case, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%%% --------------------------------------------------------------- cases ---

%% A future<u32> the host filled reads back as its value.
reads_a_future(Config) ->
    ?assertEqual({ok, 42}, read_future(Config, 42)),
    ?assertEqual({ok, 4294967295}, read_future(Config, 4294967295)).

reads_a_zero_future(Config) ->
    ?assertEqual({ok, 0}, read_future(Config, 0)).

%% A stream<u8> the host filled is drained and summed (mod 2^32).
sums_a_stream(Config) ->
    ?assertEqual({ok, 20}, sum_stream(Config, <<1, 2, 3, 4, 10>>)).

%% An empty stream sums to zero: the first read sees the writer already dropped.
sums_an_empty_stream(Config) ->
    ?assertEqual({ok, 0}, sum_stream(Config, <<>>)).

%% A stream longer than one read chunk still drains fully.
sums_a_long_stream(Config) ->
    Bytes = list_to_binary(lists:duplicate(1000, 1)),
    ?assertEqual({ok, 1000}, sum_stream(Config, Bytes)).

%%% --------------------------------------------------------------- helpers ---

read_future(Config, Value) ->
    wasm_component:call_async(?config(inst, Config), <<"run#read-future">>,
                              {[{future, u32}], u32}, [Value]).

sum_stream(Config, Bytes) ->
    wasm_component:call_async(?config(inst, Config), <<"run#sum-stream">>,
                              {[{stream, u8}], u32}, [Bytes]).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "asyncval.component.wasm"]).
