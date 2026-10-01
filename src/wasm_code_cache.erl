-module(wasm_code_cache).
-moduledoc """
Compiled code, kept on disk so a node restart does not pay for it again.

Compiling QuickJS is about twenty seconds of a core. Nothing waits for it, so it
is not a latency problem, but it is twenty seconds every time a node starts and
every time an instance of a module it has never seen goes hot. This makes it
once.

**Off unless you turn it on.** Reading a `.beam` from disk and loading it is
executing whatever is in that file, so the directory holding the cache is as
trusted as the code in your release. Wasmtime's cache is opt-in for the same
reason. Set it in the application environment:

```erlang
application:set_env(wasm, code_cache_dir, "/var/cache/my_app/wasm").
```

## What is checked, and what is only claimed

"As trusted as your release" was once only written down. It is checked now, and
the difference is worth being precise about, because the checks are narrower
than they look.

A path is refused unless it is absolute with no dot component, the directory is
owned by this node's user with no group or other write bit, **every** directory
above it is owned by root or that user and equally unwritable by others, and
nothing on the path is a symlink. An entry is refused unless it is a regular
file whose framed digest matches. Every refusal is a miss and a single line in
the log; nothing here raises, because a cache that cannot be trusted is a
slower node and never a broken one.

Ancestors are checked for **ownership** and not only for mode, which is the
part that is easy to leave out: a directory owned by somebody else at `0755` is
not group-writable, and its owner can still rename or replace everything
beneath it.

What none of it does: the digest detects **damage** -- a torn write, a bad
disk, a crash -- and not somebody who can write a well-formed entry. Validating
a path and opening a file under it are not atomic either. Neither gap is
closed, and under this model neither needs to be: once every ancestor is owned
by root or the node's user and writable by nobody else, only those two can
change what the path resolves to, and both can already run code in the node.
These checks catch misconfiguration, not an attacker who is already inside.
Trusting artifacts from a party that may *not* run code here would need them
authenticated, which this does not do.

## Why the uid comes from a probe

Nothing in Erlang answers "what uid is this node". `file:read_file_info/1`
takes an **open descriptor** as well as a name, so the answer comes from a file
this process is holding rather than from whatever a name refers to by the time
a stat runs: open a probe `exclusive`, stat the descriptor, close and delete.
Statting a path instead would be a race, and a private directory to hold it
would be a more elaborate way of not needing one.

## What a key covers

Everything that would make an artifact wrong if it changed, which is more than
the module:

- the module's content hash, so two different modules never collide
- the ABI between generated code and `wasm_exec`
- the OTP release and the emulator flavour, because generated BEAM is only
  loadable by the emulator that compiled it
- the machine's architecture
- the compiler quality asked for, since `baseline` and `full` are different code
- the *set of functions* compiled, because the tier compiles what ran and two
  workloads reach different sets
- the slot the artifact was built for, because a module's name is part of its
  BEAM file and cannot be changed without rewriting it

A module identified by a `reference()` rather than a content hash is never
cached. That is every module built from text: its identity is fresh on every
validation, so there is nothing stable to key on.

## What it does not do

No sharing between nodes, no signature, no compression. A cache entry is a file
named for the hash of its key -- framed with a magic, a format number, a length
and a digest, in the shape `wasm_snapshot_file` uses -- and eviction is by total
size, oldest first.

The rename that publishes an entry and the digest inside it do different jobs.
The rename stops a reader seeing a half-written file; it does **not** give
durability across a crash, which would need an fsync nothing here does. The
digest is what turns damage from a crash into a miss.
""".

-export([lookup/1, store/2, key/6, dir/0, purge/0]).

%% The validation policy, reachable from the suite and from nowhere else. A
%% rule about who may own a directory is this module's business, not something
%% an embedder should call and this module should then keep working.
-ifdef(TEST).
-export([leaf_ok/2, ancestor_ok/2]).
-endif.

%% Beyond this the oldest entries go. Fifteen megabytes is one QuickJS, so this
%% holds a few dozen real modules.
-include_lib("kernel/include/file.hrl").

-define(SUFFIX, ".beam").

%% The frame an entry carries. `?FORMAT' moves when the frame's shape does; an
%% entry from before framing existed has no magic, fails to match, and is a
%% miss that ages out under the size cap.
-define(MAGIC, "WASMJIT\0").
-define(FORMAT, 1).

%% The verdict table `wasm_code_slots' owns and `wasm_store' gives a lifetime
%% to. Read here, written only inside that server.
-define(PATHS, wasm_code_cache_paths).

-define(UID, {?MODULE, uid}).
-define(MAX_BYTES, 512 * 1024 * 1024).

-doc """
The artifact for this key, if there is one and it is readable.

Any failure is a miss. A cache that cannot be read is a slower start and never
an error, which is the same rule the rest of the tier follows: every refusal
means do the work.
""".
-spec lookup(binary()) -> {ok, binary()} | miss.
lookup(Key) ->
    case usable(create) of
        {ok, Dir} -> read(path(Dir, Key));
        refused   -> miss
    end.

%% A regular file, framed, whose digest matches. Anything else is a miss: a
%% symlink somebody pointed at a `.beam` of their own, a directory that happens
%% to be named like an entry, an entry from a build that framed nothing, one
%% truncated by a crash.
read(File) ->
    case file:read_link_info(File, [{time, posix}]) of
        {ok, #file_info{type = regular}} ->
            case file:read_file(File) of
                {ok, Framed} -> unframe(File, Framed);
                {error, _}   -> miss
            end;
        _ ->
            miss
    end.

unframe(File, <<?MAGIC, ?FORMAT:16, Len:32, Digest:32/binary, Beam/binary>>)
  when byte_size(Beam) =:= Len ->
    case crypto:hash(sha256, Beam) of
        Digest ->
            %% Touch it, so eviction sees which entries are in use.
            ok = wasm_file_cache:touch(File),
            {ok, Beam};
        _ ->
            miss
    end;
unframe(_File, _Other) ->
    miss.

-doc """
Keep this artifact under this key.

Written to a temporary name and renamed, because a half-written `.beam` that a
later start reads is a crash rather than a miss, and rename is atomic on every
filesystem this runs on.
""".
-spec store(binary(), binary()) -> ok.
store(Key, Bin) ->
    case usable(create) of
        refused -> ok;
        {ok, Dir} ->
            File = path(Dir, Key),
            %% `.tmp`, and not a suffix after `.beam`: `*.beam` does not match
            %% `X.beam.7`, so a temp named that way is invisible to both the
            %% sweep and the size cap and accumulates for ever.
            Tmp = filename:join(Dir, integer_to_list(erlang:unique_integer([positive]))
                                ++ ".tmp"),
            case file:write_file(Tmp, frame(Bin)) of
                ok ->
                    case file:rename(Tmp, File) of
                        ok -> ok;
                        %% Renaming can fail, and a temp nobody deletes is a
                        %% leak that no later run cleans up.
                        {error, _} -> _ = file:delete(Tmp), ok
                    end,
                    evict(Dir, File),
                    ok;
                {error, _} ->
                    _ = file:delete(Tmp),
                    ok
            end
    end.

-doc """
The key for one artifact, or `undefined` when this module cannot be cached.

`Identity` is `#module.identity`: only the `{sha256, _}` form is stable enough
to key on, and a `reference()` answers `undefined` here rather than being
hashed, because a fresh reference every validation would fill the cache with
entries nothing can ever hit.
""".
-spec key(term(), non_neg_integer(), module(), baseline | full,
          [non_neg_integer()], term()) -> binary() | undefined.
key({sha256, Hash}, Abi, Slot, Quality, Funcs, Extra) ->
    crypto:hash(sha256,
                term_to_binary({Hash, Abi, Slot, Quality, lists:sort(Funcs),
                                Extra,
                                erlang:system_info(otp_release),
                                erlang:system_info(emu_flavor),
                                erlang:system_info(system_architecture)}));
key(_Other, _Abi, _Slot, _Quality, _Funcs, _Extra) ->
    undefined.

-doc "Where the cache lives, or `undefined` when it is off.".
-spec dir() -> undefined | file:filename().
dir() -> application:get_env(wasm, code_cache_dir, undefined).

-doc "Throw the cache away. For tests, and for a release that wants a clean start.".
-spec purge() -> ok.
purge() ->
    case usable(no_create) of
        refused   -> ok;
        {ok, Dir} -> wasm_file_cache:purge(Dir, ?SUFFIX)
    end.

%%% ---------------------------------------------------------------- frame ---

%% Magic, format, length, digest, payload -- the shape `wasm_snapshot_file'
%% already uses for images, for the same reason: the bytes are about to be
%% handed to something that will act on them, so the file says what it is and
%% carries a checksum of itself.
%%
%% No ABI field, unlike the image format. `key/6' already folds the tier's ABI
%% into the filename, so an artifact from another ABI is never looked for; the
%% format number here versions this frame and nothing else.
frame(Beam) ->
    <<?MAGIC, ?FORMAT:16, (byte_size(Beam)):32,
      (crypto:hash(sha256, Beam))/binary, Beam/binary>>.

%%% ------------------------------------------------------------- the path ---

%% The directory, if it may be used at all.
%%
%% `create' says a missing leaf should be made; `no_create' says answer
%% `refused' instead, which is `purge/0': emptying a cache that does not exist
%% must not bring one into being, and must not record a verdict either, or a
%% purge before first use would leave a cache that can never exist.
usable(Create) ->
    case dir() of
        undefined ->
            refused;
        Dir when is_list(Dir); is_binary(Dir) ->
            resolve(unicode:characters_to_list(Dir), Create);
        _Bad ->
            %% Not a path at all. A miss, like everything else here.
            refused
    end.

resolve(Dir, Create) ->
    case ets:info(?PATHS, name) of
        %% No table means no application, which means no cache rather than a
        %% `badarg' out of a lookup.
        undefined -> refused;
        _         -> resolve_1(Dir, Create)
    end.

resolve_1(Dir, Create) ->
    case ets:lookup(?PATHS, Dir) of
        [{Dir, {ok, _} = Ok}] -> Ok;
        [{Dir, _Refused}]     -> refused;
        [] -> judge(Dir, Create)
    end.

%% Everything from here to the row being written runs inside
%% `wasm_code_slots', once per path, for the reason its own doc gives: creating
%% a directory is a `make_dir' and then a chmod, and a second process looking
%% between the two sees a world-writable directory and would record a refusal
%% that outlives the mistake.
%%
%% A caller that cannot reach the server, or waits too long for it, gets
%% `refused' for this call and **records nothing**. The work may still be in
%% flight and the next call will find the row.
judge(Dir, no_create) ->
    case check(Dir) of
        {ok, _} = Ok -> Ok;
        _            -> refused
    end;
judge(Dir, create) ->
    try wasm_code_slots:cache_verdict(Dir, fun() -> initialise(Dir) end) of
        {ok, _} = Ok -> Ok;
        _            -> refused
    catch
        _:_ -> refused
    end.

initialise(Dir) ->
    Verdict = create_then_check(Dir),
    ok = say(Dir, Verdict),
    Verdict.

create_then_check(Dir) ->
    case file:read_link_info(Dir, [{time, posix}]) of
        {error, enoent} -> create(Dir);
        _               -> check(Dir)
    end.

%% The leaf only. `filelib:ensure_path/1', which this used to call, makes a
%% whole missing chain, and every directory it invents is one this code would
%% then have to secure with a umask window of its own. A missing ancestor is a
%% refusal instead, and the guide says so.
create(Dir) ->
    case check_ancestors(filename:dirname(Dir)) of
        {refused, _} = R ->
            R;
        ok ->
            case file:make_dir(Dir) of
                %% Somebody else won the race. Theirs is as good as ours: fall
                %% through and judge what is there.
                {error, eexist} -> check(Dir);
                {error, Why}    -> {refused, {cannot_create, Why}};
                ok              -> secure(Dir)
            end
    end.

secure(Dir) ->
    _ = file:change_mode(Dir, 8#700),
    %% `make_dir/1' respects the umask, so this directory existed at whatever
    %% the umask allowed until the line above. Anyone who could write in that
    %% window could have left something in it, so a directory we have just made
    %% and find non-empty is not ours to trust.
    case file:list_dir(Dir) of
        {ok, []} -> check(Dir);
        {ok, _}  -> {refused, created_but_not_empty};
        {error, Why} -> {refused, {cannot_list, Why}}
    end.

%%% ------------------------------------------------------------ the checks ---

check(Dir) ->
    case os:type() of
        %% uid and Unix mode bits are what every rule here is written in. On a
        %% system that has neither there is nothing to check, so there is
        %% nothing to trust.
        {unix, _} -> check_unix(Dir);
        Other     -> {refused, {not_posix, Other}}
    end.

check_unix(Dir) ->
    case shape(Dir) of
        {refused, _} = R -> R;
        ok               -> check_leaf(Dir)
    end.

%% The cache directory itself, which is held to more than its ancestors are:
%% they may belong to root, this one may not. Root owning the directory a node
%% writes its artifacts into means something else can put artifacts there.
check_leaf(Dir) ->
    case stat(Dir) of
        {refused, _} = R ->
            R;
        {ok, Info} ->
            case leaf_ok(Info, uid()) of
                false -> {refused, {leaf, Dir}};
                true  -> check_above(Dir)
            end
    end.

check_above(Dir) ->
    case check_ancestors(filename:dirname(Dir)) of
        {refused, _} = R -> R;
        ok               -> {ok, Dir}
    end.

%% The path itself, before a single stat: absolute, and spelled only one way.
%% A relative path means something different after `file:set_cwd/1', and a dot
%% component would let `/srv/c' and `/srv/./c' be judged separately and
%% recorded twice.
shape(Dir) ->
    case filename:pathtype(Dir) of
        absolute ->
            case [C || C <- filename:split(Dir), C =:= "." orelse C =:= ".."] of
                [] -> ok;
                _  -> {refused, dot_component}
            end;
        _ ->
            {refused, not_absolute}
    end.

%% Up to the root. An ancestor owned by somebody else can rename what is under
%% it however tight the leaf's own mode is, so ownership is checked the whole
%% way and not only at the end.
check_ancestors(Dir) ->
    case stat(Dir) of
        {refused, _} = R ->
            R;
        {ok, Info} ->
            case ancestor_ok(Info, uid()) of
                false -> {refused, {ancestor, Dir}};
                true ->
                    case filename:dirname(Dir) of
                        Dir  -> ok;              %% the root answers itself
                        Up   -> check_ancestors(Up)
                    end
            end
    end.

stat(Dir) ->
    case file:read_link_info(Dir, [{time, posix}]) of
        {ok, Info}   -> {ok, Info};
        {error, Why} -> {refused, {cannot_stat, Dir, Why}}
    end.

-doc """
Whether one directory on the path is one this node may trust, and whether the
last one may hold the cache.

Pure, and exported in the test profile only, so the policy can be asserted
without building a filesystem or holding a privilege. Both halves matter:
`leaf_ok/2` is what the cache directory itself must satisfy, `ancestor_ok/2`
what everything above it must, and the difference is ownership -- an ancestor
may belong to root, the leaf may not.
""".
-spec leaf_ok(#file_info{}, non_neg_integer()) -> boolean().
leaf_ok(#file_info{type = directory, mode = Mode, uid = Uid}, Me) ->
    Mode band 8#022 =:= 0 andalso Uid =:= Me;
leaf_ok(_Info, _Me) ->
    false.

-spec ancestor_ok(#file_info{}, non_neg_integer()) -> boolean().
ancestor_ok(#file_info{type = directory, mode = Mode, uid = Uid}, Me) ->
    Mode band 8#022 =:= 0 andalso (Uid =:= Me orelse Uid =:= 0);
ancestor_ok(_Info, _Me) ->
    false.

%%% -------------------------------------------------------------- the uid ---

%% This node's effective uid, which Erlang exposes nowhere directly.
%%
%% A probe, then, and the shape of it is the point: `file:read_file_info/1`
%% takes an **open descriptor** as well as a name, so the answer comes from the
%% file this process holds rather than from whatever the name refers to by the
%% time the stat runs. Opened `exclusive' so it is ours or nothing.
uid() ->
    case persistent_term:get(?UID, undefined) of
        undefined ->
            Uid = probe_uid(),
            persistent_term:put(?UID, Uid),
            Uid;
        Uid ->
            Uid
    end.

probe_uid() ->
    Path = filename:join(tmp_dir(), "wasm-uid-" ++
                             integer_to_list(erlang:unique_integer([positive]))),
    case file:open(Path, [exclusive, raw, write, binary]) of
        {ok, Fd} ->
            try
                case file:read_file_info(Fd, [{time, posix}]) of
                    {ok, #file_info{uid = Uid}} -> Uid;
                    {error, _}                  -> unknown
                end
            after
                _ = file:close(Fd),
                _ = file:delete(Path)
            end;
        {error, _} ->
            unknown
    end.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        ""    -> "/tmp";
        D     -> D
    end.

%%% ------------------------------------------------------------- the words ---

%% Once per path, and it is once because this runs inside the server's critical
%% section: a directory that is silently never used is a node that is slow for
%% no visible reason, and a directory that warns on every lookup is a log
%% nobody reads.
say(_Dir, {ok, _}) ->
    ok;
say(Dir, {refused, Why}) ->
    logger:warning("wasm: code_cache_dir ~ts is not usable (~p); the compiled "
                   "tier will recompile on every start. It must be an absolute "
                   "path, owned by this node's user, with no group or other "
                   "write bit on it or any directory above it, and nothing on "
                   "the path a symlink.", [Dir, Why]).

%%% -------------------------------------------------------------- private ---

path(Dir, Key) ->
    filename:join(Dir, binary_to_list(binary:encode_hex(Key)) ++ ?SUFFIX).

%% Oldest first, until the total is under the cap, with stale temporaries swept
%% on the way. The policy is `wasm_file_cache`, shared with the snapshot image
%% store, which had none and grew without bound until it was lifted out of
%% here. `Keep` is the entry just written, which is never the one dropped.
evict(Dir, Written) ->
    wasm_file_cache:sweep_and_evict(Dir, ?SUFFIX, ?MAX_BYTES, Written).
