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
     a_failed_file_write_is_reported,
     a_failed_socket_write_is_reported,
     two_append_streams_both_append,
     an_output_stream_outlives_its_descriptor,
     a_write_without_a_permit_traps,
     a_permit_covers_exactly_one_write,
     a_write_larger_than_the_permit_traps,
     a_closed_sink_stays_closed].

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
    H = wasi_preview2:new_output_stream({file, own, Fh, 0}),
    ?assertMatch({error, _}, wasi_preview2:write_stream(H, <<"lost?">>)),
    wasm_component:host_drop(H).

%% A socket-backed output stream reports a failed send instead of swallowing it.
%% The socket is not connected, so the send fails. Fail-first: the socket sink
%% used to return `ok` unconditionally, losing the write silently.
a_failed_socket_write_is_reported(_Config) ->
    %% A socket-backed output stream carries a wasi_sock2 handle (the TCP backend);
    %% a write to an unconnected socket is reported as an error, not swallowed.
    {ok, Sock} = wasi_sock2:open(inet),
    H = wasi_preview2:new_output_stream({socket, Sock}),
    ?assertMatch({error, _}, wasi_preview2:write_stream(H, <<"x">>)),
    wasm_component:host_drop(H),
    wasi_sock2:close(Sock).

%% Two append streams on the same file both append rather than overwriting. Each
%% write goes to the current end. Fail-first: the append offset was captured once
%% at stream creation, so the second stream wrote over the first (abcB not abcAB).
two_append_streams_both_append(Config) ->
    Dir = ?config(priv_dir, Config),
    ok = filelib:ensure_path(filename:join(Dir, "append")),
    {ok, Root} = wasi_fs:preopen(filename:join(Dir, "append")),
    {ok, Fh} = wasi_fs:open(Root, <<"f">>, [read, write, create]),
    {ok, _} = wasi_fs:pwrite(Fh, 0, <<"abc">>),
    S1 = wasi_preview2:new_output_stream({file_append, own, Fh}),
    S2 = wasi_preview2:new_output_stream({file_append, own, Fh}),
    ok = wasi_preview2:write_stream(S1, <<"A">>),
    ok = wasi_preview2:write_stream(S2, <<"B">>),
    ?assertEqual({ok, <<"abcAB">>}, wasi_fs:pread(Fh, 0, 5)),
    wasm_component:host_drop(S1), wasm_component:host_drop(S2).

%% An output stream taken from a descriptor keeps working after the descriptor is
%% dropped: on the native backend it owns a duplicated handle. Fail-first: the
%% output stream used to share the descriptor's handle, so closing it broke the
%% stream with EBADF.
an_output_stream_outlives_its_descriptor(Config) ->
    case wasi_fs:backend() of
        fallback -> {skip, "fallback cannot duplicate a handle"};
        native ->
            Dir = ?config(priv_dir, Config),
            ok = filelib:ensure_path(filename:join(Dir, "outlive")),
            {ok, Root} = wasi_fs:preopen(filename:join(Dir, "outlive")),
            {ok, Fh} = wasi_fs:open(Root, <<"f">>, [write, create]),
            {ok, Dup} = wasi_fs:dup(Fh),
            S = wasi_preview2:new_output_stream({file, own, Dup, 0}),
            ok = wasi_fs:close(Fh),
            ok = wasi_preview2:write_stream(S, <<"kept">>),
            {ok, Rd} = wasi_fs:open(Root, <<"f">>, [read]),
            ?assertEqual({ok, <<"kept">>}, wasi_fs:pread(Rd, 0, 4)),
            wasm_component:host_drop(S)
    end.

%% wasi-io requires a `check-write` permit before an ordinary `write`; a write
%% with none violates the ABI and traps. Fail-first: the pre-permit write path had
%% no permit state and let the write through.
a_write_without_a_permit_traps(_Config) ->
    H = wasi_preview2:new_output_stream(fun(_) -> ok end),
    ?assertMatch({error, _},
                 wasm_error:capture(fun() -> wasi_preview2:permit_write(H, <<"x">>) end)),
    wasm_component:host_drop(H).

%% A permit granted by check-write covers one write and is then consumed: the
%% first write goes through, a second without a fresh check-write traps.
a_permit_covers_exactly_one_write(_Config) ->
    Self = self(),
    H = wasi_preview2:new_output_stream(fun(B) -> Self ! {out, B}, ok end),
    {ok, Permit} = wasi_preview2:check_write(H),
    ?assert(Permit > 0),
    ?assertEqual(ok, wasi_preview2:permit_write(H, <<"a">>)),
    ?assertEqual(<<"a">>, receive {out, B} -> B after 0 -> none end),
    ?assertMatch({error, _},
                 wasm_error:capture(fun() -> wasi_preview2:permit_write(H, <<"b">>) end)),
    wasm_component:host_drop(H).

%% A write larger than the granted permit traps rather than being trusted.
a_write_larger_than_the_permit_traps(_Config) ->
    H = wasi_preview2:new_output_stream(fun(_) -> ok end),
    {ok, Permit} = wasi_preview2:check_write(H),
    Big = binary:copy(<<0>>, Permit + 1),
    ?assertMatch({error, _},
                 wasm_error:capture(fun() -> wasi_preview2:permit_write(H, Big) end)),
    wasm_component:host_drop(H).

%% A sink whose reader is gone reports `closed`; once closed the stream stays
%% closed, so check-write reports closed instead of granting a fresh permit and a
%% later write is refused. Fail-first: check-write always returned ok(budget).
a_closed_sink_stays_closed(_Config) ->
    H = wasi_preview2:new_output_stream(fun(_) -> closed end),
    ?assertEqual({error, closed}, wasi_preview2:write_stream(H, <<"x">>)),
    ?assertEqual({error, {<<"closed">>, undefined}}, wasi_preview2:check_write(H)),
    ?assertEqual({error, closed}, wasi_preview2:write_stream(H, <<"y">>)),
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
