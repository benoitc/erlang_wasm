-module(wasm_wasi2_iofull_SUITE).
-moduledoc """
A component that uses more of `wasi:io` runs against the Preview 2 host
(`wasi_preview2:io/1`).

Beyond the one-shot write and read, this covers the output write path
(`check-write` then `write` then `blocking-flush`), and the readiness model
(`subscribe` to a `pollable`, then `poll`). The guest exports `pump` (returns the
check-write budget and writes its bytes), `peek` (subscribes stdin and polls),
and `drain` (reads the source back). See `scripts/build-component-fixture.sh`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_write_path_reaches_the_sink,
     a_synchronous_pollable_is_ready,
     the_source_still_reads_back].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% pump asks check-write for a budget, writes the bytes, and flushes. The budget
%% crosses back as a u64 and the bytes reach the sink.
the_write_path_reaches_the_sink(Config) ->
    Self = self(),
    {ok, I} = instance(Config, #{sink => fun(B) -> Self ! {out, B}, ok end}),
    [begin
         ?assertEqual(65536, pump(I, B)),
         ?assertEqual(B, iolist_to_binary(drain_mailbox()))
     end || B <- [<<>>, <<"line">>, binary:copy(<<$q>>, 9000)]],
    ?assertEqual([], wasm_component:host_live()).

%% A pollable over a synchronous stream polls ready at once.
a_synchronous_pollable_is_ready(Config) ->
    {ok, I} = instance(Config, #{}),
    ?assertEqual(true, peek(I)),
    ?assertEqual([], wasm_component:host_live()).

%% The read path still returns the whole source (regression through the fuller
%% fixture and its extra imports).
the_source_still_reads_back(Config) ->
    Src = crypto:strong_rand_bytes(12000),
    {ok, I} = instance(Config, #{source => Src}),
    ?assertEqual(Src, drain(I)).

%%% -------------------------------------------------------------- helpers ---

pump(I, Bytes) ->
    {ok, N} = wasm_component:call(I, <<"pump">>, {[{list, u8}], u64}, [Bytes]),
    N.

peek(I) ->
    {ok, V} = wasm_component:call(I, <<"peek">>, {[], bool}, []),
    V.

drain(I) ->
    {ok, V} = wasm_component:call(I, <<"drain">>, {[], {list, u8}}, []),
    V.

drain_mailbox() ->
    receive {out, B} -> [B | drain_mailbox()] after 0 -> [] end.

instance(Config, Opts) ->
    wasm_component:instantiate(?config(component, Config), wasi_preview2:io(Opts)).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiiofull.component.wasm"]).
