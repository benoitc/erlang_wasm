-module(wasi_nif_SUITE).
-moduledoc """
The native path backend, and the race it exists to close.

`wasi_fs` has two backends and both must refuse every escape. The native one
additionally has to refuse a symlink swapped in *after* a path was checked,
which is the whole reason it exists and the one thing the fallback cannot do.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

all() ->
    [backend_is_reported_honestly,
     legitimate_paths_open,
     every_escape_is_refused,
     symlink_swapped_after_check_is_refused,
     handles_survive_arbitrary_input,
     closing_a_handle_under_a_read_never_yields_another_file,
     a_root_replaced_after_it_was_opened_is_not_followed,
     path_operations_refuse_what_the_walk_refuses].

init_per_testcase(_Case, Config) ->
    Priv = ?config(priv_dir, Config),
    Root = filename:join(Priv, integer_to_list(erlang:unique_integer([positive]))),
    Data = filename:join(Root, "data"),
    Secret = filename:join(Root, "secret"),
    ok = filelib:ensure_path(filename:join(Data, "sub")),
    ok = filelib:ensure_path(Secret),
    ok = file:write_file(filename:join(Data, "note.txt"), <<"hello">>),
    ok = file:write_file(filename:join(Secret, "key.txt"), <<"TOPSECRET">>),
    _ = file:make_symlink(filename:join(Secret, "key.txt"),
                          filename:join(Data, "escape.txt")),
    _ = file:make_symlink(Secret, filename:join(Data, "outdir")),
    [{data, Data}, {secret, Secret} | Config].

end_per_testcase(_, _) -> ok.

%% The preopen is a directory, opened once. Naming it by path on every open
%% would leave it to be resolved again every time, so replacing it between two
%% opens would silently move the sandbox somewhere else while the guest went on
%% holding what it thinks is the same capability.
%%
%% Anchored, operations continue against the directory that was opened. That is
%% the point rather than a side effect: a capability is a thing, not a name.
a_root_replaced_after_it_was_opened_is_not_followed(Config) ->
    case wasi_fs:backend() of
        fallback ->
            {skip, "the fallback resolves by name, which is the race"};
        native ->
            Data = ?config(data, Config),
            Root = root(Data),
            ?assertMatch({ok, _}, wasi_fs:open(Root, ~"note.txt", [read])),

            %% Swap the whole preopen for a directory holding somebody's
            %% secrets, under the same name.
            Decoy = filename:join(filename:dirname(Data), "decoy"),
            ok = filelib:ensure_path(Decoy),
            ok = file:write_file(filename:join(Decoy, "note.txt"), ~"SWAPPED"),
            ok = file:rename(Data, Data ++ ".moved"),
            ok = file:rename(Decoy, Data),

            {ok, H} = wasi_fs:open(Root, ~"note.txt", [read]),
            ?assertEqual({ok, ~"hello"}, wasi_fs:pread(H, 0, 5)),
            ok = wasi_fs:close(H),
            ok = wasi_fs:forget(Root)
    end.

%% A preopen is a directory opened once, not a path resolved on every open, so
%% the tests take one the same way `wasi_preview1` does.
root(Path) ->
    {ok, Root} = wasi_fs:preopen(Path),
    Root.

%% Two processes sharing a descriptor is ordinary: a guest hands one to an
%% agent, or a worker times out and something closes while a read is in flight.
%% Every operation used to test the descriptor and then use it with nothing in
%% between, and the interleaving is not a crash. `close(7)` returns the number
%% to the kernel, the next open in any thread of the VM gets 7 back, and the
%% read already in flight reads whatever that now is: a WASI guest asks for one
%% file and is handed the contents of another.
%%
%% So the assertion is not that nothing crashed. It is that no read ever
%% returned a byte belonging to a different file.
closing_a_handle_under_a_read_never_yields_another_file(Config) ->
    case wasi_fs:backend() of
        fallback -> {skip, "no native backend built"};
        native -> race_rounds(?config(data, Config), 6000)
    end.

race_rounds(Dir, Rounds) ->
    Root = unicode:characters_to_list(Dir),
    ok = file:write_file(filename:join(Dir, "mine"), binary:copy(<<$A>>, 4096)),
    Decoys = [begin
                  N = "decoy" ++ integer_to_list(K),
                  ok = file:write_file(filename:join(Dir, N),
                                       binary:copy(<<$B>>, 4096)),
                  list_to_binary(N)
              end || K <- lists:seq(1, 32)],
    Wrong = lists:sum([race_round(Root, Decoys) || _ <- lists:seq(1, Rounds)]),
    ?assertEqual(0, Wrong).

race_round(Root, Decoys) ->
    {ok, H} = wasi_file_nif:open_at(Root, ~"mine", 0, 0),
    Self = self(),
    %% Six readers and six thousand rounds, because the window is the few
    %% instructions between testing the descriptor and using it. Four hundred
    %% rounds with one reader never hit it; this reproduces thirteen crossed
    %% reads against 619ff01.
    Readers = [spawn(fun() -> Self ! {read, foreign_bytes(H, 60, 0)} end)
               || _ <- lists:seq(1, 6)],
    _ = spawn(fun() -> wasi_file_nif:close(H) end),
    %% Churning opens is what makes the kernel hand the closed number straight
    %% back out, which is the whole mechanism of the defect.
    _ = spawn(fun() ->
                  [wasi_file_nif:open_at(Root, D, 0, 0) || D <- Decoys],
                  ok
              end),
    lists:sum([receive {read, N} -> N
               after 10000 -> ct:fail(reader_stuck)
               end || _ <- Readers]).

foreign_bytes(_H, 0, N) -> N;
foreign_bytes(H, Left, N) ->
    Wrong = case wasi_file_nif:pread(H, 0, 64) of
                {ok, Bin} ->
                    case binary:match(Bin, <<$B>>) of
                        nomatch -> 0;
                        _ -> 1
                    end;
                %% `eof` and any errno are fine: refusing is correct, and so is
                %% succeeding on the file that was actually asked for.
                _ -> 0
            end,
    foreign_bytes(H, Left - 1, N + Wrong).

backend_is_reported_honestly(_Config) ->
    %% Either is valid; what matters is that the answer matches reality, since
    %% the security properties differ between them.
    ?assert(lists:member(wasi_fs:backend(), [native, fallback])),
    ?assertEqual(wasi_fs:backend() =:= native, wasi_file_nif:available()).

legitimate_paths_open(Config) ->
    Data = ?config(data, Config),
    {ok, H} = wasi_fs:open(root(Data), ~"note.txt", [read]),
    ?assertEqual({ok, <<"hello">>}, wasi_fs:pread(H, 0, 64)),
    ok = wasi_fs:close(H),
    {ok, H2} = wasi_fs:open(root(Data), ~"./note.txt", [read]),
    ok = wasi_fs:close(H2).

%% Both backends must refuse all of these, and with ENOTCAPABLE rather than
%% ENOENT so the error cannot be used to probe the host's layout.
%% With `follow', which is the setting that can actually escape.
%%
%% Without it the walk refuses every symlink outright and this would pass
%% whether or not containment worked. `follow' is what a guest gets when it
%% passes `LOOKUPFLAGS_SYMLINK_FOLLOW', and it is where the link text is read
%% and walked, so it is the only setting under which the property means
%% anything.
every_escape_is_refused(Config) ->
    Data = ?config(data, Config),
    [begin
         Result = wasi_fs:open(root(Data), P, [read, follow]),
         ?assertMatch({P, {error, _}}, {P, Result}),
         {error, E} = Result,
         ?assertEqual({P, ?ENOTCAPABLE}, {P, E})
     end || P <- [~"../secret/key.txt",
                  ~"escape.txt",
                  ~"outdir/key.txt",
                  ~"sub/../../secret/key.txt",
                  ~"/etc/passwd"]].

%% The race the NIF exists for: resolve a path, then swap a component for a
%% symlink before it is opened. The fallback is documented as vulnerable here,
%% so this only asserts against the native backend.
symlink_swapped_after_check_is_refused(Config) ->
    case wasi_fs:backend() of
        fallback ->
            {skip, "fallback is documented as racy; nothing to assert"};
        native ->
            Data = ?config(data, Config),
            Secret = ?config(secret, Config),
            Victim = filename:join(Data, "swapme.txt"),
            ok = file:write_file(Victim, <<"innocent">>),
            %% A check now would pass. Swap it before the open.
            ok = file:delete(Victim),
            ok = file:make_symlink(filename:join(Secret, "key.txt"), Victim),
            %% Following, so the swap is actually resolved rather than refused
            %% for being a link at all. See `every_escape_is_refused'.
            ?assertEqual({error, ?ENOTCAPABLE},
                         wasi_fs:open(root(Data), ~"swapme.txt",
                                      [read, follow])),
            %% And the secret really was reachable, so the refusal is the
            %% sandbox working rather than the file being absent.
            ?assertEqual({ok, <<"TOPSECRET">>},
                         file:read_file(filename:join(Secret, "key.txt")))
    end.

%% Fuzz the boundary. Whatever is thrown at it, it must return a value and must
%% not take down the VM.
handles_survive_arbitrary_input(Config) ->
    Data = ?config(data, Config),
    Paths = [~"", ~".", ~"..", ~"/", ~"//", ~"./.", ~"a/b/c/d/e",
             <<0:8>>, <<"note.txt", 0:8, "junk">>, binary:copy(~"a/", 600),
             binary:copy(~"x", 5000), ~"note.txt/", ~"sub/"],
    [begin
         R = wasi_fs:open(root(Data), P, [read]),
         ?assert(R =:= {error, element(2, R)} orelse element(1, R) =:= ok,
                 {bad_shape, P, R}),
         case R of
             {ok, H} -> wasi_fs:close(H);
             _ -> ok
         end
     end || P <- Paths],
    %% Random bytes as paths, and random offsets and lengths against a real
    %% handle: nothing here may crash.
    {ok, H} = wasi_fs:open(root(Data), ~"note.txt", [read]),
    [begin
         _ = wasi_fs:pread(H, Off, Len),
         _ = wasi_fs:open(root(Data), crypto:strong_rand_bytes(rand:uniform(40)), [read])
     end || {Off, Len} <- [{0, 0}, {0, 1}, {1000000, 10}, {0, 1000000}]],
    ok = wasi_fs:close(H),
    %% Double close must be safe.
    ok = wasi_fs:close(H).

%% The eight `path_*` calls used to resolve a name and then act on it, two
%% steps with a window between them. They act through the same component walk
%% now: every directory along the way opened with `O_NOFOLLOW`, then one `*at`
%% call against a descriptor nobody can substitute.
%%
%% So they refuse exactly what opening refuses, which is what this asserts.
%% `..` never leaves the root, an absolute path is not reinterpreted, and a
%% symlink is not traversed even to reach a name inside the sandbox.
path_operations_refuse_what_the_walk_refuses(Config) ->
    case wasi_fs:backend() of
        fallback ->
            {skip, "the fallback resolves by name, which is the other backend"};
        native ->
            Root = root(?config(data, Config)),
            Escapes = [~"../secret/key.txt", ~"/etc/passwd",
                       ~"outdir/key.txt", ~"sub/../../secret/key.txt"],
            [begin
                 ?assertMatch({error, _}, wasi_fs:stat(Root, P)),
                 ?assertMatch({error, _}, wasi_fs:mkdir(Root, P)),
                 ?assertMatch({error, _}, wasi_fs:unlink(Root, P)),
                 ?assertMatch({error, _}, wasi_fs:rmdir(Root, P)),
                 ?assertMatch({error, _}, wasi_fs:symlink(Root, P, ~"x")),
                 ?assertMatch({error, _}, wasi_fs:readlink(Root, P)),
                 ?assertMatch({error, _}, wasi_fs:rename(Root, ~"note.txt",
                                                         Root, P)),
                 ?assertMatch({error, _}, wasi_fs:link(Root, ~"note.txt",
                                                       Root, P))
             end || P <- Escapes],

            %% And what is inside still works, through the same walk.
            ?assertMatch({ok, #{type := regular}},
                         wasi_fs:stat(Root, ~"note.txt")),
            ?assertEqual(ok, wasi_fs:mkdir(Root, ~"made")),
            ?assertMatch({ok, #{type := directory}},
                         wasi_fs:stat(Root, ~"made")),
            ?assertEqual(ok, wasi_fs:rmdir(Root, ~"made")),
            ?assertEqual(ok, wasi_fs:symlink(Root, ~"lnk", ~"note.txt")),
            ?assertEqual({ok, ~"note.txt"}, wasi_fs:readlink(Root, ~"lnk")),
            %% Stat does not follow the final component either: a link's own
            %% stat is about the link.
            ?assertMatch({ok, #{type := symlink}}, wasi_fs:stat(Root, ~"lnk")),
            ?assertEqual(ok, wasi_fs:unlink(Root, ~"lnk")),
            ?assertEqual(ok, wasi_fs:rename(Root, ~"note.txt", Root, ~"moved")),
            ?assertMatch({ok, _}, wasi_fs:stat(Root, ~"moved")),
            ?assertEqual(ok, wasi_fs:rename(Root, ~"moved", Root, ~"note.txt")),
            ok = wasi_fs:forget(Root)
    end.
