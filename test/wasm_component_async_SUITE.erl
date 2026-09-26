-module(wasm_component_async_SUITE).
-moduledoc """
Typed `future<T>` and `stream<T>` over the async Canonical ABI, against a real guest.

The fixture (`scripts/build-component-fixture.sh`, `asyncval`) is a wit-bindgen
async guest exporting `read-future: async func(future<u32>) -> u32` and
`sum-stream: async func(stream<u8>) -> u32`. Each case hands the guest the readable
end of a pre-filled future or stream through `wasm_component:call_async/4`; the guest
reads it and returns a value, so `future.read`/`stream.read` (copying the element
into guest memory and reporting the Canonical ABI completion code) are exercised
end to end.

The EAGER cases pre-fill the readable end, so the reads complete at once and the callee
runs straight to `task.return` (no suspension). The remaining cases drive the real
suspend/resume executor: the read blocks (BLOCKED), the callee returns WAIT, and a
completion arrives from a producer (queued before the guest runs, or released only after
the owner is provably waiting via a `wait_hook` handshake), which the executor delivers
through the guest's callback until it exits.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [reads_a_future, reads_a_zero_future, sums_a_stream,
     sums_an_empty_stream, sums_a_long_stream,
     reads_a_future_ready_before_wait, reads_a_future_from_a_delayed_producer,
     sums_a_streamed_producer, a_producer_crash_is_reported,
     join_transfers_and_drop_traps,
     makes_a_future, makes_a_stream].

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

%%% ----------------------------------------------------- suspend/resume ---

%% A future whose completion is already queued before the guest runs: the read blocks
%% (so the WAIT handler runs, waits/0 == 1), and the executor finds the completion
%% without blocking. Runs in this process, so waits/0 reads its own count.
reads_a_future_ready_before_wait(Config) ->
    ?assertEqual({ok, 42}, read_future(Config, {ready_before, 42})),
    ?assertEqual(1, wasm_async:waits()).

%% A future delivered by a producer that fires ONLY after the owner reports it is
%% waiting (the wait_hook handshake), so the owner provably blocked first.
reads_a_future_from_a_delayed_producer(Config) ->
    Self = self(),
    PFun = fun(#{owner := O, task_ref := R, handle := H}) ->
               Self ! {producer_up, self()},
               receive go -> O ! {async_ready, R, H, {value, 77}} end
           end,
    Owner = spawn_owner(Config, <<"run#read-future">>, {[{future, u32}], u32},
                        [{producer, PFun}], #{wait_hook => Self}),
    Prod = recv({producer_up, prod}),
    recv({async_wait}),
    Prod ! go,
    ?assertEqual({ok, 77, 1}, recv({result})),
    _ = Owner.

%% A stream fed one chunk per wait round, then closed: several suspend/resume cycles,
%% each released only after the owner signals it is waiting.
sums_a_streamed_producer(Config) ->
    Self = self(),
    PFun = fun(#{owner := O, task_ref := R, handle := H}) ->
               Self ! {producer_up, self()},
               Send = fun(I) -> receive go -> O ! {async_ready, R, H, I} end end,
               Send({data, <<1, 2, 3>>}), Send({data, <<4, 10>>}), Send(close)
           end,
    _Owner = spawn_owner(Config, <<"run#sum-stream">>, {[{stream, u8}], u32},
                         [{producer, PFun}], #{wait_hook => Self}),
    Prod = recv({producer_up, prod}),
    Result = relay_until_result(Prod),
    ?assertEqual({ok, 20, 3}, Result).

%% A producer that dies without supplying its value surfaces as an error, not a hang.
a_producer_crash_is_reported(Config) ->
    PFun = fun(_Ctx) -> exit(boom) end,
    _Owner = spawn_owner(Config, <<"run#read-future">>, {[{future, u32}], u32},
                         [{producer, PFun}], #{}),
    {Res, _Waits} = recv({result2}),
    ?assertMatch({error, {producer_failed, _}}, Res).

%% Joining a waitable transfers it (at most one set), so its old set empties (drop ok)
%% and its new set is non-empty (drop traps). Exercised through the built-ins directly.
join_transfers_and_drop_traps(Config) ->
    ok = wasm_async:begin_task(?config(inst, Config), #{}),
    try
        New = wasm_async:builtin(waitable_set_new, #{}),
        Join = wasm_async:builtin(waitable_join, #{}),
        Drop = wasm_async:builtin(waitable_set_drop, #{}),
        {ok, [A]} = New(#{}, []),
        {ok, [B]} = New(#{}, []),
        W = 9999,
        {ok, []} = Join(#{}, [W, A]),
        {ok, []} = Join(#{}, [W, B]),           %% transfers W from A to B
        ?assertEqual({ok, []}, Drop(#{}, [A])), %% A is now empty
        ?assertEqual({trap, waitable_set_not_empty}, Drop(#{}, [B]))
    after
        wasm_async:end_task()
    end.

%%% ------------------------------------------------------- producer direction ---

%% The guest CREATES a future, writes a value, and returns the reader; the host reads
%% the produced value back. Exercises future.new/future.write and lifting a future
%% result (an i32 handle), including a value above the signed-byte range.
makes_a_future(Config) ->
    ?assertEqual({ok, 42}, make_future(Config, 42)),
    ?assertEqual({ok, 200}, make_future(Config, 200)).

%% The guest creates a stream, writes `count` copies of a byte, returns the reader; the
%% host reads the produced bytes. Exercises stream.new/stream.write and a stream result.
makes_a_stream(Config) ->
    ?assertEqual({ok, <<7, 7, 7>>}, make_stream(Config, 7, 3)),
    ?assertEqual({ok, <<>>}, make_stream(Config, 0, 0)).

make_future(Config, X) ->
    wasm_component:call_async(?config(inst, Config), <<"run#make-future">>,
                              {[u8], {future, u8}}, [X]).

make_stream(Config, Byte, Count) ->
    wasm_component:call_async(?config(inst, Config), <<"run#make-stream">>,
                              {[u8, u32], {stream, u8}}, [Byte, Count]).

%%% --------------------------------------------------------------- helpers ---

%% Run call_async in its own process (a bare instance is process-scoped, and the
%% producer cases need the owner separate from the coordinating test process). The
%% owner instantiates, runs, reports {result, Value, Waits} (or {result2, {Res,Waits}}),
%% and destroys.
spawn_owner(Config, Export, Sig, Args, Opts) ->
    Bin = ?config(component, Config),
    Self = self(),
    spawn(fun() ->
              {ok, Inst} = wasm_component:instantiate(Bin),
              Res = try wasm_component:call_async(Inst, Export, Sig, Args, Opts)
                    catch C:E -> {caught, C, E} end,
              Waits = wasm_async:waits(),
              ok = wasm_component:destroy(Inst),
              case Res of
                  {ok, V} -> Self ! {result, V, Waits};
                  _       -> Self ! {result2, {Res, Waits}}
              end
          end).

%% Release the next chunk on every wait signal until the owner reports its result.
relay_until_result(Prod) ->
    receive
        {async_wait, _Ref, _Set} -> Prod ! go, relay_until_result(Prod);
        {result, V, W}           -> {ok, V, W}
    after 8000 ->
        timeout
    end.

recv({producer_up, prod}) -> receive {producer_up, P} -> P after 5000 -> timeout end;
recv({async_wait})        -> receive {async_wait, _, _} -> ok after 5000 -> timeout end;
recv({result})           -> receive {result, V, W} -> {ok, V, W} after 8000 -> timeout end;
recv({result2})          -> receive {result2, RW} -> RW after 8000 -> timeout end.

read_future(Config, Value) ->
    wasm_component:call_async(?config(inst, Config), <<"run#read-future">>,
                              {[{future, u32}], u32}, [Value]).

sum_stream(Config, Bytes) ->
    wasm_component:call_async(?config(inst, Config), <<"run#sum-stream">>,
                              {[{stream, u8}], u32}, [Bytes]).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "asyncval.component.wasm"]).
