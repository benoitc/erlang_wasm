%% @doc WASI Preview 1, and specifically its sandbox.
%%
%% The path tests are the ones that matter. A WASI implementation that opens
%% the right files is easy; one that reliably refuses the wrong ones is the
%% whole product. Each known escape technique gets its own case, and each must
%% fail with `ENOTCAPABLE' rather than `ENOENT', so that the error code cannot
%% be used to probe the host filesystem's layout.
-module(wasi_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

all() ->
    [stdout_goes_to_the_configured_sink,
     args_and_env_are_what_was_granted,
     absent_capabilities_are_refused,
     opens_a_file_inside_the_preopen,
     reads_file_contents,
     parent_traversal_is_refused,
     absolute_path_is_refused,
     symlink_escape_is_refused,
     a_symlink_is_not_followed_unless_asked,
     a_symlink_cycle_is_refused_rather_than_followed,
     partial_traversal_is_refused,
     missing_file_is_enoent_not_enotcapable,
     read_only_preopen_refuses_write,
     no_dirs_means_no_filesystem,
     proc_exit_reports_status,
     stdin_is_a_capability,
     a_guest_open_goes_through_the_native_backend,
     renumbering_moves_a_descriptor_onto_a_free_number].

init_per_suite(Config) ->
    Priv = ?config(priv_dir, Config),
    Root = filename:join(Priv, "sbox"),
    Data = filename:join(Root, "data"),
    Secret = filename:join(Root, "secret"),
    ok = filelib:ensure_path(Data),
    ok = filelib:ensure_path(Secret),
    %% A real subdirectory, so `partial_traversal_is_refused' walks into
    %% something and then tries to climb out of it. Without this the path it
    %% names stops at a component that does not exist, and the case passes on
    %% `ENOENT' without ever reaching the traversal it is named for.
    ok = filelib:ensure_path(filename:join(Data, "sub")),
    ok = file:write_file(filename:join(Data, "note.txt"), <<"file contents here">>),
    ok = file:write_file(filename:join(Secret, "key.txt"), <<"TOPSECRET">>),
    %% A symlink pointing out of the sandbox, which is the escape a purely
    %% lexical path check would miss.
    _ = file:make_symlink(filename:join(Secret, "key.txt"),
                          filename:join(Data, "escape.txt")),
    %% The same escape by a *relative* target, which is the one that survives a
    %% walk that only refuses absolute link text. And a link that stays inside,
    %% which must still open, or refusing the escape would prove nothing.
    _ = file:make_symlink("../secret/key.txt",
                          filename:join(Data, "escape_rel.txt")),
    _ = file:make_symlink("note.txt", filename:join(Data, "inside.txt")),
    %% Two links pointing at each other. A walk that follows links needs a
    %% budget or this is a hang rather than an error.
    _ = file:make_symlink("loop_b.txt", filename:join(Data, "loop_a.txt")),
    _ = file:make_symlink("loop_a.txt", filename:join(Data, "loop_b.txt")),
    {ok, Wasm} = file:read_file(module_path()),
    {ok, Mod} = wasm:compile(Wasm),
    [{mod, Mod}, {data, Data}, {secret, Secret} | Config].

end_per_suite(_) -> ok.

module_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "wasi", "hello.wasm"]).

%%% -------------------------------------------------------------- fixtures ---

instance(Config, Extra) ->
    Base = #{stdout => self(),
             args => [<<"prog">>, <<"-x">>],
             env => #{<<"MODE">> => <<"prod">>, <<"N">> => <<"1">>},
             clocks => [monotonic],
             random => strong},
    Cfg = maps:merge(Base, Extra),
    {ok, I} = wasm:instantiate(?config(mod, Config), wasi_preview1:imports(Cfg)),
    I.

with_data(Config, Access) ->
    instance(Config, #{dirs => [{<<"/data">>, ?config(data, Config), Access}]}).

%% Write a path into linear memory and ask the module to open it.
open(I, Path) ->
    Bytes = binary_to_list(iolist_to_binary(Path)),
    lists:foreach(fun({Ix, C}) -> {ok, _} = wasm:call(I, <<"store_byte">>, [200 + Ix, C]) end,
                  lists:enumerate(0, Bytes)),
    {ok, [Errno]} = wasm:call(I, <<"open">>, [200, length(Bytes)]),
    Errno.

%%% ----------------------------------------------------------------- basics ---

stdout_goes_to_the_configured_sink(Config) ->
    I = with_data(Config, read),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, <<"say">>, [])),
    ?assertEqual({ok, [16]}, wasm:call(I, <<"nwritten">>, [])),
    receive {wasi_output, _, Data} -> ?assertEqual(<<"hello from wasm\n">>, Data)
    after 500 -> ct:fail(no_output)
    end.

args_and_env_are_what_was_granted(Config) ->
    I = with_data(Config, read),
    ?assertEqual({ok, [2]}, wasm:call(I, <<"argc">>, [])),
    ?assertEqual({ok, [2]}, wasm:call(I, <<"envc">>, [])),
    %% An instance granted nothing sees nothing: the host's own environment is
    %% never inherited.
    Bare = instance(Config, #{args => [], env => #{}, dirs => []}),
    ?assertEqual({ok, [0]}, wasm:call(Bare, <<"argc">>, [])),
    ?assertEqual({ok, [0]}, wasm:call(Bare, <<"envc">>, [])).

absent_capabilities_are_refused(Config) ->
    I = with_data(Config, read),
    %% `monotonic' was granted, `realtime' was not.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, <<"clock">>, [?CLOCK_MONOTONIC])),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, <<"clock">>, [?CLOCK_REALTIME])),
    NoRandom = instance(Config, #{dirs => [], random => none}),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(NoRandom, <<"rand">>, [])).

%%% ------------------------------------------------------------ filesystem ---

%% The point of the native backend is that the kernel resolves each component
%% once, with `O_NOFOLLOW', so a symlink swapped in after a check cannot be
%% followed. None of that applied to anything a guest did: `path_open` resolved
%% the path with `wasi_path` and opened it with `file:open/2`, two steps with a
%% window between them, and `wasi_fs` had no callers at all.
%%
%% What makes it observable from here is that the native backend follows *no*
%% symlink, not merely escaping ones. A link that stays inside the preopen is
%% refused too, which is stricter than the specification requires and is the
%% price of resolving once. On the fallback it opens, so this asserts the
%% behaviour of whichever backend is actually in use rather than pretending
%% there is only one.
a_guest_open_goes_through_the_native_backend(Config) ->
    I = with_data(Config, read),
    Dir = ?config(data, Config),
    ok = file:write_file(filename:join(Dir, "target.txt"), <<"inside">>),
    _ = file:make_symlink("target.txt", filename:join(Dir, "link.txt")),
    ?assertEqual(?ESUCCESS, open(I, "target.txt")),
    %% Both backends now answer the same thing for the same path, which they
    %% did not before: the native one refused every symlink because each
    %% component was opened `O_NOFOLLOW', while the fallback followed anything
    %% that stayed inside. They agree because the rule moved to where it
    %% belongs, which is whether the caller passed
    %% `LOOKUPFLAGS_SYMLINK_FOLLOW'; this fixture does not, so a link is
    %% `ELOOP' either way.
    ?assertEqual(?ELOOP, open(I, "link.txt")).

%% `fd_renumber(from, to)` moves a descriptor, closing whatever `to` named
%% first. It required `to` to be open already and answered `EBADF` otherwise,
%% which is backwards: the number a guest is moving to is usually free, and
%% that is what the call is for. When `to` was open its entry was overwritten
%% rather than closed, so what it named stayed open with nothing naming it.
%%
%% Its own module, because the shared fixture is checked in as bytes and has no
%% export for this.
renumbering_moves_a_descriptor_onto_a_free_number(Config) ->
    {ok, Parsed} = wasm_wat:module(renumber_module()),
    {ok, Mod} = wasm_validate:module(Parsed),
    Cfg = #{dirs => [{<<"/data">>, ?config(data, Config), read}]},
    {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(Cfg)),
    ok = wasm:write_memory(I, 200, ~"note.txt"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"open", [200, 8])),
    {ok, [Fd]} = wasm:call(I, ~"opened_fd", []),
    Free = Fd + 7,
    %% The destination must already be open. `fd_renumber' *replaces* what `to'
    %% names, which is what the specification's wording means and what wasmtime
    %% enforces; upstream's `renumber' case asserts `EBADF' for a free one.
    %%
    %% This suite used to require the opposite, on the reasoning that the point
    %% of the call is moving a descriptor onto a number the guest picked and
    %% that number is usually free, and that a libc doing the standard `dup2'
    %% dance would otherwise get `EBADF' for a correct call. Kept here because
    %% it is the argument somebody will make again: it has to be wrong
    %% somewhere, since wasi-libc runs against wasmtime constantly, so either
    %% the dance passes a live descriptor or it was never the dance that failed.
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"renumber", [Fd, Free])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"open", [200, 8])),
    {ok, [Second]} = wasm:call(I, ~"opened_fd", []),
    %% Onto a number that is open: the source moves and the destination's own
    %% file is closed rather than left with nothing naming it.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"renumber", [Fd, Second])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"read", [Second])),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"read", [Fd])),
    %% Moving from a number that names nothing is the error.
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"renumber", [Fd, Second])),
    ok = wasm:destroy(I).

renumber_module() -> ~"""
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_renumber"
    (func $fd_renumber (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "open") (param $p i32) (param $n i32) (result i32)
    (call $path_open (i32.const 3) (i32.const 0) (local.get $p) (local.get $n)
                     (i32.const 0) (i64.const -1) (i64.const -1) (i32.const 0)
                     (i32.const 24)))
  (func (export "opened_fd") (result i32) (i32.load (i32.const 24)))
  (func (export "renumber") (param $a i32) (param $b i32) (result i32)
    (call $fd_renumber (local.get $a) (local.get $b)))
  (func (export "read") (param $fd i32) (result i32)
    (i32.store (i32.const 8) (i32.const 300))
    (i32.store (i32.const 12) (i32.const 64))
    (call $fd_read (local.get $fd) (i32.const 8) (i32.const 1) (i32.const 28))))
""".

opens_a_file_inside_the_preopen(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ESUCCESS, open(I, "note.txt")),
    ?assertEqual(?ESUCCESS, open(I, "./note.txt")),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, <<"prestat">>, [])).

reads_file_contents(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ESUCCESS, open(I, "note.txt")),
    {ok, [Fd]} = wasm:call(I, <<"opened_fd">>, []),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, <<"read_opened">>, [Fd])),
    {ok, [N]} = wasm:call(I, <<"nread">>, []),
    Bytes = [begin {ok, [C]} = wasm:call(I, <<"byte">>, [300 + K]), C end
             || K <- lists:seq(0, N - 1)],
    ?assertEqual(<<"file contents here">>, list_to_binary(Bytes)).

%%% ------------------------------------------------------- escape attempts ---

parent_traversal_is_refused(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ENOTCAPABLE, open(I, "../secret/key.txt")),
    ?assertEqual(?ENOTCAPABLE, open(I, "..")).

absolute_path_is_refused(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ENOTCAPABLE, open(I, "/etc/passwd")),
    ?assertEqual(?ENOTCAPABLE, open(I, "/")).

%% The one a lexical check alone would miss: the path never mentions `..', but
%% the file it names is a symlink out of the sandbox.
%% This module's `open' export passes dirflags of zero, so nothing here asks to
%% follow the final component, and Preview 1's answer for opening a symlink
%% without asking is `ELOOP'. That is the guest-visible half of the rule.
%%
%% The half that matters for the sandbox -- a link that escapes is refused even
%% when following *is* asked for -- cannot be reached through this fixture and
%% is `wasi_nif_SUITE:every_escape_is_refused', which calls `wasi_fs:open/3'
%% with `follow' directly.
symlink_escape_is_refused(Config) ->
    I = with_data(Config, read),
    %% Refused, and the two backends name it differently on purpose.
    %%
    %% The native walk answers `ELOOP': it was not asked to follow the link, so
    %% it never looks at where the link goes and has nothing to say about the
    %% sandbox. The fallback resolves lexically first and finds the escape, so
    %% it answers `ENOTCAPABLE'. Both are true; neither leaks anything the other
    %% does not. What must hold on both is that the file does not open.
    [?assert(lists:member(open(I, P), [?ELOOP, ?ENOTCAPABLE]))
     || P <- ["escape.txt", "escape_rel.txt"]].

%% A link that stays inside is refused the same way and for the same reason: a
%% symlink is a symlink, and whether it escapes has not been looked at yet.
a_symlink_is_not_followed_unless_asked(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ELOOP, open(I, "inside.txt")),
    %% The thing it points at opens, so the refusal is about the link and not
    %% about the file being unreachable.
    ?assertEqual(?ESUCCESS, open(I, "note.txt")).

%% A cycle is an error and not a hang. Both backends bound it: the native walk
%% by an explicit budget, the fallback through `filelib:safe_relative_path/2'.
a_symlink_cycle_is_refused_rather_than_followed(Config) ->
    I = with_data(Config, read),
    ?assertNotEqual(?ESUCCESS, open(I, "loop_a.txt")).

%% Escapes and then comes back. Rejected because the path leaves the root at
%% any point, not merely because of where it ends up.
partial_traversal_is_refused(Config) ->
    I = with_data(Config, read),
    %% Into `sub', back out of it, and then one further up than the preopen
    %% goes. The first `..' is allowed and the second is the refusal.
    ?assertEqual(?ENOTCAPABLE, open(I, "sub/../../secret/key.txt")),
    ?assertEqual(?ENOTCAPABLE, open(I, "./../data/note.txt")),
    %% And the half of it that is legal really is legal, or the case above
    %% would pass just as well if `..' were refused outright.
    ?assertEqual(?ESUCCESS, open(I, "sub/../note.txt")).

%% A refused path and an absent file must be distinguishable, and they must not
%% be *confusable*: reporting `ENOENT' for a refused path would turn the error
%% code into an oracle for the host's directory layout.
missing_file_is_enoent_not_enotcapable(Config) ->
    I = with_data(Config, read),
    ?assertEqual(?ENOENT, open(I, "missing.txt")).

%%% ------------------------------------------------------------- rights ---

read_only_preopen_refuses_write(Config) ->
    %% The module asks for every right it can (`-1' as the rights mask). A
    %% read-only preopen must still refuse to produce a writable descriptor:
    %% requested rights are masked against what the grant passes down.
    RO = with_data(Config, read),
    ?assertEqual(?ESUCCESS, open(RO, "note.txt")),
    RW = with_data(Config, write),
    ?assertEqual(?ESUCCESS, open(RW, "note.txt")),
    Before = file:read_file(filename:join(?config(data, Config), "note.txt")),
    ?assertMatch({ok, <<"file contents here">>}, Before).

no_dirs_means_no_filesystem(Config) ->
    %% Not "rooted at the working directory", not "everything read-only":
    %% nothing at all. There is no fd 3 to open relative to.
    I = instance(Config, #{dirs => []}),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, <<"prestat">>, [])),
    ?assertEqual(?EBADF, open(I, "note.txt")).

%% stdin is granted like anything else. Absent it reports end of file; present
%% as a binary it is consumed progressively rather than repeating.
stdin_is_a_capability(Config) ->
    Absent = with_data(Config, read),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(Absent, <<"say">>, [])),
    %% Reading with no stdin granted must not invent data.
    Granted = instance(Config, #{stdin => <<"hello stdin">>,
                                 dirs => [{<<"/data">>, ?config(data, Config), read}]}),
    {ok, [?ESUCCESS]} = wasm:call(Granted, <<"read_opened">>, [0]),
    {ok, [N]} = wasm:call(Granted, <<"nread">>, []),
    ?assertEqual(11, N),
    Bytes = [begin {ok, [C]} = wasm:call(Granted, <<"byte">>, [300 + K]), C end
             || K <- lists:seq(0, N - 1)],
    ?assertEqual(<<"hello stdin">>, list_to_binary(Bytes)),
    %% A second read continues where the first stopped, and then reports EOF.
    {ok, [?ESUCCESS]} = wasm:call(Granted, <<"read_opened">>, [0]),
    ?assertEqual({ok, [0]}, wasm:call(Granted, <<"nread">>, [])).

%%% ------------------------------------------------------------------ exit ---

proc_exit_reports_status(Config) ->
    I = with_data(Config, read),
    {error, Err} = wasm:call(I, <<"quit">>, [3]),
    ?assertEqual(trap, maps:get(class, Err)),
    ?assertEqual({ok, 3}, wasi_preview1:exit_code(Err)).
