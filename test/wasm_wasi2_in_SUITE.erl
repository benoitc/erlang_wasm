-module(wasm_wasi2_in_SUITE).
-moduledoc """
A component that reads the input side of `wasi:io` runs against the Preview 2
host (`wasi_preview2:io/1` with a `source`).

The host owns an `input-stream` over a source binary: `wasi:cli/stdin.get-stdin`
mints the handle, `blocking-read` hands out the source in chunks and signals
`stream-error::closed` at the end, and the drop frees the handle. The guest
imports `wasi:cli/stdin` and `wasi:io/streams` and exports `slurp`, which reads
until closed and returns everything (see `scripts/build-component-fixture.sh`).
These cases prove the guest reads back exactly the source, that the end-of-stream
`closed` error crosses the ABI, and that an empty source reads nothing.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_source_reads_back_whole,
     an_empty_source_reads_nothing,
     the_handle_is_freed_after_reading].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% slurp reads chunk by chunk until `closed` and reassembles the whole source,
%% across a vector of sizes (several are larger than the guest's 4096 read, so
%% the loop and the closed signal both run).
the_source_reads_back_whole(Config) ->
    [begin
         {ok, I} = instance(Config, Src),
         ?assertEqual(Src, slurp(I))
     end || Src <- [<<"one read">>, binary:copy(<<$a>>, 4096),
                    binary:copy(<<$b>>, 10000), rand_bin(65537)]].

%% An empty source reads back nothing: the first read is already `closed`.
an_empty_source_reads_nothing(Config) ->
    {ok, I} = instance(Config, <<>>),
    ?assertEqual(<<>>, slurp(I)).

%% The input-stream handle is gone once the guest has read and dropped it.
the_handle_is_freed_after_reading(Config) ->
    ?assertEqual([], wasm_component:host_live()),
    {ok, I} = instance(Config, <<"payload">>),
    _ = slurp(I),
    ?assertEqual([], wasm_component:host_live()).

%%% -------------------------------------------------------------- helpers ---

slurp(I) ->
    {ok, V} = wasm_component:call(I, <<"slurp">>, {[], {list, u8}}, []),
    V.

instance(Config, Source) ->
    wasm_component:instantiate(?config(component, Config),
                               wasi_preview2:io(#{source => Source})).

rand_bin(N) -> crypto:strong_rand_bytes(N).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiin.component.wasm"]).
