-module(wasi_p3_filesystem).
-moduledoc """
`wasi:filesystem` at 0.3: the same preopened descriptors as
`wasi_p2_filesystem`, through the 0.3 interface.

The operations are `wasi_p2_filesystem`'s, so the sandbox and the read-only
mounts are one implementation. What changes is the interface: reads, writes and
directory listings go through streams, every other call is an `async func`
(which completes at once here, since the operation does), error codes and
descriptor types are variants with an `other` case, and timestamps are signed.
""".

-export([filesystem/1]).

-define(TYPES, ~"wasi:filesystem/types@0.3").
-define(ERRORS,
        [~"access", ~"already", ~"bad-descriptor", ~"busy", ~"deadlock", ~"quota",
         ~"exist", ~"file-too-large", ~"illegal-byte-sequence", ~"in-progress",
         ~"interrupted", ~"invalid", ~"io", ~"is-directory", ~"loop",
         ~"too-many-links", ~"message-size", ~"name-too-long", ~"no-device",
         ~"no-entry", ~"no-lock", ~"insufficient-memory", ~"insufficient-space",
         ~"not-directory", ~"not-empty", ~"not-recoverable", ~"unsupported",
         ~"no-tty", ~"no-such-device", ~"overflow", ~"not-permitted", ~"pipe",
         ~"read-only", ~"invalid-seek", ~"text-file-busy", ~"cross-device"]).
-define(ERROR_CODE,
        {variant, [{E, none} || E <- ?ERRORS] ++ [{~"other", {option, string}}]}).
-define(TYPE_NAMES,
        [~"block-device", ~"character-device", ~"directory", ~"fifo",
         ~"symbolic-link", ~"regular-file", ~"socket"]).
-define(DESC_TYPE,
        {variant, [{T, none} || T <- ?TYPE_NAMES] ++ [{~"other", {option, string}}]}).
-define(INSTANT, {record, [{~"seconds", s64}, {~"nanoseconds", u32}]}).
-define(STAT,
        {record, [{~"type", ?DESC_TYPE}, {~"link-count", u64}, {~"size", u64},
                  {~"data-access-timestamp", {option, ?INSTANT}},
                  {~"data-modification-timestamp", {option, ?INSTANT}},
                  {~"status-change-timestamp", {option, ?INSTANT}}]}).
-define(PATH_FLAGS, {flags, [~"symlink-follow"]}).
-define(OPEN_FLAGS, {flags, [~"create", ~"directory", ~"exclusive", ~"truncate"]}).
-define(DESC_FLAGS,
        {flags, [~"read", ~"write", ~"file-integrity-sync", ~"data-integrity-sync",
                 ~"requested-write-sync", ~"mutate-directory"]}).
-define(NEW_TIMESTAMP,
        {variant, [{~"no-change", none}, {~"now", none}, {~"timestamp", ?INSTANT}]}).
-define(ADVICE,
        {enum, [~"normal", ~"sequential", ~"random", ~"will-need", ~"dont-need",
                ~"no-reuse"]}).
-define(HASH, {record, [{~"lower", u64}, {~"upper", u64}]}).
-define(DIR_ENTRY, {record, [{~"type", ?DESC_TYPE}, {~"name", string}]}).
-define(UNIT, {result, none, ?ERROR_CODE}).
-define(STATUS, {future, ?UNIT}).
%% The most a file takes from one write: a larger one is a short write, which
%% the guest finishes by writing the rest.
-define(WRITE_CHUNK, 65536).

-doc """
`wasi:filesystem` at 0.3 over the mounts in `Opts`, as for
`wasi_p2_filesystem:filesystem/1`.
""".
-spec filesystem(map()) -> #{{binary(), binary()} => term()}.
filesystem(Opts) ->
    Mounts = wasi_p2_filesystem:mounts_of(Opts),
    P2 = wasi_p2_filesystem,
    Method = fun(Name) -> <<"[method]descriptor.", Name/binary>> end,
    Async = fun(Name, Sig, Fun) -> {{?TYPES, Method(Name)}, {async_import, Sig, Fun}} end,
    maps:from_list(
      [{{~"wasi:filesystem/preopens@0.3", ~"get-directories"},
        wasm_component:import_fun({[], {list, {tuple, [handle, string]}}},
                                  fun([]) -> P2:get_directories(Mounts) end)},
       {{?TYPES, ~"[resource-drop]descriptor"},
        fun(_Ctx, [H]) -> _ = P2:fs_drop(H), {ok, []} end},
       {{?TYPES, Method(~"read-via-stream")},
        wasm_component:import_fun({[handle, u64], {tuple, [{stream, u8}, ?STATUS]}},
                                  fun([F, Off]) -> read_via_stream(F, Off) end)},
       {{?TYPES, Method(~"write-via-stream")},
        wasm_component:import_fun({[handle, {stream, u8}, u64], ?STATUS},
                                  fun([F, S, Off]) -> write_via_stream(F, S, {at, Off}) end)},
       {{?TYPES, Method(~"append-via-stream")},
        wasm_component:import_fun({[handle, {stream, u8}], ?STATUS},
                                  fun([F, S]) -> write_via_stream(F, S, append) end)},
       {{?TYPES, Method(~"read-directory")},
        wasm_component:import_fun({[handle], {tuple, [{stream, ?DIR_ENTRY}, ?STATUS]}},
                                  fun([D]) -> read_directory(D) end)},
       Async(~"advise", {[handle, u64, u64, ?ADVICE], ?UNIT},
             fun(_) -> {ok, undefined} end),
       Async(~"sync-data", {[handle], ?UNIT}, fun([H]) -> unit(P2:sync_fd(H)) end),
       Async(~"sync", {[handle], ?UNIT}, fun([H]) -> unit(P2:sync_fd(H)) end),
       Async(~"get-flags", {[handle], {result, ?DESC_FLAGS, ?ERROR_CODE}},
             fun([H]) -> err(P2:get_flags(H)) end),
       Async(~"get-type", {[handle], {result, ?DESC_TYPE, ?ERROR_CODE}},
             fun([H]) -> type_result(P2:type_of(H)) end),
       Async(~"set-size", {[handle, u64], ?UNIT},
             fun([H, Size]) -> unit(P2:set_size(H, Size)) end),
       Async(~"set-times", {[handle, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP], ?UNIT},
             fun([H, A, M]) -> unit(P2:set_times(H, A, M)) end),
       Async(~"set-times-at",
             {[handle, ?PATH_FLAGS, string, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP], ?UNIT},
             fun([D, PF, P, A, M]) -> unit(P2:set_times_at(D, PF, P, A, M)) end),
       Async(~"create-directory-at", {[handle, string], ?UNIT},
             fun([D, P]) -> unit(P2:create_directory_at(D, P)) end),
       Async(~"stat", {[handle], {result, ?STAT, ?ERROR_CODE}},
             fun([H]) -> stat_result(P2:stat(H)) end),
       Async(~"stat-at", {[handle, ?PATH_FLAGS, string], {result, ?STAT, ?ERROR_CODE}},
             fun([D, PF, P]) -> stat_result(P2:stat_at(D, PF, P)) end),
       Async(~"link-at", {[handle, ?PATH_FLAGS, string, handle, string], ?UNIT},
             fun([D, PF, P, ND, NP]) -> unit(P2:link_at(D, PF, P, ND, NP)) end),
       Async(~"open-at",
             {[handle, ?PATH_FLAGS, string, ?OPEN_FLAGS, ?DESC_FLAGS],
              {result, handle, ?ERROR_CODE}},
             fun([D, PF, P, OF, DF]) -> err(P2:open_at(D, PF, P, OF, DF)) end),
       Async(~"readlink-at", {[handle, string], {result, string, ?ERROR_CODE}},
             fun([D, P]) -> err(P2:readlink_at(D, P)) end),
       Async(~"remove-directory-at", {[handle, string], ?UNIT},
             fun([D, P]) -> unit(P2:remove_directory_at(D, P)) end),
       Async(~"rename-at", {[handle, string, handle, string], ?UNIT},
             fun([D, P, ND, NP]) -> unit(P2:rename_at(D, P, ND, NP)) end),
       Async(~"symlink-at", {[handle, string, string], ?UNIT},
             fun([D, Old, New]) -> unit(P2:symlink_at(D, Old, New)) end),
       Async(~"unlink-file-at", {[handle, string], ?UNIT},
             fun([D, P]) -> unit(P2:unlink_file_at(D, P)) end),
       Async(~"is-same-object", {[handle, handle], bool},
             fun([A, B]) -> P2:is_same_object(A, B) end),
       Async(~"metadata-hash", {[handle], {result, ?HASH, ?ERROR_CODE}},
             fun([H]) -> err(P2:metadata_hash(H)) end),
       Async(~"metadata-hash-at", {[handle, ?PATH_FLAGS, string],
                                   {result, ?HASH, ?ERROR_CODE}},
             fun([D, PF, P]) -> err(P2:metadata_hash_at(D, PF, P)) end)]).

%%% ------------------------------------------------------------- streams ---

%% The file from `Off', read now and fed to the guest's stream by a producer,
%% then ended; the future reports how reading went.
read_via_stream(File, Off) ->
    {Data, Status} =
        case wasi_p2_filesystem:type_of(File) of
            {ok, ~"directory"} -> {<<>>, {error, {~"is-directory", undefined}}};
            _ ->
                case wasi_p2_filesystem:readable_file(File) of
                    {ok, Handle} ->
                        case wasi_p2_filesystem:read_all(Handle, Off, <<>>) of
                            {ok, Bytes} -> {Bytes, {ok, undefined}};
                            {error, Errno} ->
                                {<<>>, {error, code(wasi_p2_filesystem:errno_name(Errno))}}
                        end;
                    {error, E} -> {<<>>, {error, code(E)}}
                end
        end,
    {feed(u8, Data), resolved(Status)}.

%% Every write the guest makes to its stream goes to the file as it is made;
%% the future resolves when the guest ends the stream, or at the first error.
write_via_stream(File, Stream, Where) ->
    {R, W} = wasm_async:host_future(?UNIT),
    case writable(File) of
        ok ->
            Off = case Where of {at, O} -> O; append -> undefined end,
            Pos = counters:new(1, []),
            ok = counters:put(Pos, 1, case Off of undefined -> 0; _ -> Off end),
            Sink = fun(eof) ->
                           _ = wasm_async:host_future_resolve(W, {ok, undefined}),
                           ok;
                      (Bytes) ->
                           At = case Where of
                                    append -> end_of(File);
                                    _ -> counters:get(Pos, 1)
                                end,
                           case wasi_p2_filesystem:write_at(File, Bytes, At) of
                               {ok, N} -> ok = counters:put(Pos, 1, At + N), ok;
                               {error, E} ->
                                   _ = wasm_async:host_future_resolve(W, {error, code(E)}),
                                   closed
                           end
                   end,
            ok = wasm_async:host_sink(Stream, Sink, ?WRITE_CHUNK);
        {error, E} ->
            ok = wasm_async:host_sink(Stream, fun(_) -> closed end),
            ok = wasm_async:host_future_resolve(W, {error, code(E)})
    end,
    R.

writable(File) ->
    case wasi_p2_filesystem:get_flags(File) of
        {ok, Flags} ->
            case lists:member(~"write", Flags) of
                true -> ok;
                false -> {error, ~"bad-descriptor"}
            end;
        {error, _} = E -> E
    end.

end_of(File) ->
    case wasi_p2_filesystem:stat(File) of
        {ok, #{~"size" := Size}} -> Size;
        _ -> 0
    end.

read_directory(Dir) ->
    case wasi_p2_filesystem:dir_entries(Dir) of
        {ok, Entries} ->
            {feed(?DIR_ENTRY, [E#{~"type" => desc_type(T)} || #{~"type" := T} = E <- Entries]),
             resolved({ok, undefined})};
        {error, E} ->
            {feed(?DIR_ENTRY, []), resolved({error, code(E)})}
    end.

%% A stream the guest reads: a producer sends `Items' and ends it.
feed(Desc, Items) ->
    R = wasm_async:new_stream_channel(Desc),
    ok = wasm_async:register_producer(
           R, fun(#{owner := O, task_ref := Ref, handle := H}) ->
                      O ! {async_ready, Ref, H, {data, Items}},
                      O ! {async_ready, Ref, H, close}
              end),
    R.

resolved(Value) ->
    {R, W} = wasm_async:host_future(?UNIT),
    ok = wasm_async:host_future_resolve(W, Value),
    R.

%%% -------------------------------------------------------------- shapes ---

%% 0.2's enum error names become 0.3's variant; `would-block', gone in 0.3,
%% is `other'.
code(Name) ->
    case lists:member(Name, ?ERRORS) of
        true -> {Name, undefined};
        false -> {~"other", {some, Name}}
    end.

err({ok, V}) -> {ok, V};
err({error, E}) -> {error, code(E)}.

unit({ok, _}) -> {ok, undefined};
unit({error, E}) -> {error, code(E)}.

desc_type(Name) ->
    case lists:member(Name, ?TYPE_NAMES) of
        true -> {Name, undefined};
        false -> {~"other", none}
    end.

type_result({ok, T}) -> {ok, desc_type(T)};
type_result({error, E}) -> {error, code(E)}.

stat_result({ok, #{~"type" := T} = S}) -> {ok, S#{~"type" => desc_type(T)}};
stat_result({error, E}) -> {error, code(E)}.
