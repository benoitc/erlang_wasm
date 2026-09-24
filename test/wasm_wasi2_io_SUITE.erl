-module(wasm_wasi2_io_SUITE).
-moduledoc """
A component that imports the output side of `wasi:io` runs against the Preview 2
host (`wasi_preview2:io/1`).

This is the first host-owned resource: the host owns an `output-stream`, mints
an `own` handle, hands it to the guest through `wasi:cli/stdout.get-stdout`, and
implements `blocking-write-and-flush` and the drop. The guest imports
`wasi:cli/stdout` and `wasi:io/streams` and exports `emit`, which gets stdout,
writes the bytes, and drops the stream (see `scripts/build-component-fixture.sh`).
These cases prove the bytes reach the host's sink, the handle is freed on drop,
and repeated use neither leaks nor loses order.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [bytes_written_reach_the_sink,
     the_handle_is_freed_after_use,
     two_emits_accumulate,
     a_failed_file_write_is_reported].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% Every emitted chunk reaches the sink unchanged, across a vector of inputs.
bytes_written_reach_the_sink(Config) ->
    [begin
         {ok, I} = instance(Config, sink()),
         ok = emit(I, B),
         ?assertEqual(B, iolist_to_binary(drain()))
     end || B <- [<<>>, <<"x">>, <<"hello, world">>, binary:copy(<<$z>>, 5000)]].

%% The stream handle the guest minted is gone from the host table once emit
%% returns: get-stdout minted it, the guest's drop freed it. Fail-first: drop
%% the `[resource-drop]output-stream` wiring from wasi_preview2:io/1 and the
%% handle stays live here.
the_handle_is_freed_after_use(Config) ->
    ?assertEqual([], wasm_component:host_live()),
    {ok, I} = instance(Config, sink()),
    ok = emit(I, <<"data">>),
    ?assertEqual([], wasm_component:host_live()).

%% Two emits on the same instance write in order and leave nothing behind: each
%% mints, writes and drops its own handle.
two_emits_accumulate(Config) ->
    {ok, I} = instance(Config, sink()),
    ok = emit(I, <<"ab">>),
    ok = emit(I, <<"cd">>),
    ?assertEqual(<<"abcd">>, iolist_to_binary(drain())),
    ?assertEqual([], wasm_component:host_live()).

%% A write to a file-backed stream whose pwrite fails is reported, not dropped.
%% The stream carries a closed descriptor, so pwrite returns EBADF; write_stream
%% must surface it. Fail-first: the pre-fix branch returned `ok` on a pwrite error,
%% so the bytes were silently lost.
a_failed_file_write_is_reported(Config) ->
    Dir = ?config(priv_dir, Config),
    {ok, Root} = wasi_fs:preopen(Dir),
    {ok, Fh} = wasi_fs:open(Root, <<"f">>, [write, create]),
    ok = wasi_fs:close(Fh),
    H = wasm_component:host_new(output_stream, {file, Fh, 0}),
    ?assertMatch({error, _}, wasi_preview2:write_stream(H, <<"lost?">>)),
    wasm_component:host_drop(H).

%%% -------------------------------------------------------------- helpers ---

%% A sink that forwards each chunk to this process, so the test reads them back.
sink() ->
    Self = self(),
    wasi_preview2:io(#{sink => fun(B) -> Self ! {out, B}, ok end}).

drain() ->
    receive {out, B} -> [B | drain()] after 0 -> [] end.

emit(I, Bytes) ->
    {ok, undefined} =
        wasm_component:call(I, <<"emit">>, {[{list, u8}], none}, [Bytes]),
    ok.

instance(Config, Imports) ->
    wasm_component:instantiate(?config(component, Config), Imports).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiio.component.wasm"]).
