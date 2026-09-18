-module(wasm_snapshot_store).
-moduledoc """
A directory of snapshot images, keyed by what makes one valid.

Shaped on `wasm_code_cache`, which is the existing precedent for a build
artifact kept on disk and looked up by identity: a flat directory named by app
env, absent meaning off, one file per key, write to a temporary name and
rename, and a total size past which the oldest go. The policy itself is
`wasm_file_cache`, shared with that module.

```erlang
application:set_env(wasm, snapshot_dir, "/var/cache/wasm/images").
```

Off unless that is set, and **the directory is as trusted as your release**.
That is the same concession `wasm_code_cache` makes, and it carries further
here: a cache entry is code, which a release already trusts, while an image is
guest state laid into a live runtime. What bounds the damage is that every
field is validated on the way in and a table slot may name only a function the
module has, which is containment rather than authentication.

## What the key covers, and the one thing it deliberately does not

An image is a runtime after `init()` ran **against a particular environment**,
so the key has to cover the environment and not only the module. It is the
module hash, the format's own ABI, the adapter's version, and the adapter's
compatibility key -- and that last one is where a preopened directory, an
argument list or a set of environment variables has to be accounted for. An
adapter that leaves it `undefined` cannot be cached, because there would be
nothing distinguishing two images captured from different worlds.

It does **not** cover the OTP release, the emulator flavour or the machine's
architecture, all three of which `wasm_code_cache:key/6` includes. That is the
difference between the two artifacts rather than an oversight: a `.beam` is
genuinely specific to an emulator, while an image is bytes, integers and
indices, and one that would not load on another machine could not be moved.
""".

-export([dir/0, key/4, lookup/2, store/3, purge/0, max_bytes/0]).

-define(SUFFIX, ".img").

%% The same number `wasm_code_cache` uses. A **file** here is 35 KB for Lua and
%% 2.7 MB for CPython, a 77x spread, which is why this one is a setting and that
%% one is not: the right size depends entirely on the guest.
%%
%% Note which of an image's three sizes this bounds. It is the file, not the
%% 7.4 MB a started CPython retains in memory (`max_snapshot_bytes`) and not the
%% 41.9 MB of address space it covers (`max_memory_pages`). `docs/snapshots.md`
%% has the three side by side.
-define(MAX_BYTES, 512 * 1024 * 1024).
-define(WARNED, {?MODULE, warned_bad_max}).

-doc "Where images live, or `undefined`, which means the store is off.".
-spec dir() -> undefined | file:filename().
dir() -> application:get_env(wasm, snapshot_dir, undefined).

-doc """
The key an image is filed under.

`undefined` when the adapter supplied no compatibility key, which the caller
must read as "do not cache this" rather than as a key of its own.
""".
-spec key(binary(), binary(), term(), pos_integer()) -> binary() | undefined.
key(_Hash, _Version, undefined, _Abi) ->
    undefined;
key(Hash, Version, CompatKey, Abi) ->
    crypto:hash(sha256, term_to_binary({Hash, Version, CompatKey, Abi})).

-doc """
The image filed under this key, for a module the caller names.

**Every failure is a miss.** A corrupt file, one written by another build, one
naming another module: none of them is an error, because the caller's answer to
all of them is the same and it is to capture instead. `wasm_code_cache` states
that contract for its own reads; this one keeps it.
""".
-spec lookup(binary() | undefined, wasm:module_()) ->
          {ok, wasm:snapshot()} | miss.
lookup(undefined, _Handle) ->
    miss;
lookup(Key, Handle) ->
    case dir() of
        undefined -> miss;
        Dir       -> read(path(Dir, Key), Handle)
    end.

read(Path, Handle) ->
    case wasm:load_snapshot(Path, Handle) of
        {ok, Image} ->
            %% Least-recently-used rather than least-recently-written, which
            %% is what makes the size cap evict the right thing.
            ok = wasm_file_cache:touch(Path),
            {ok, Image};
        {error, _} ->
            miss
    end.

-doc """
File an image, or do nothing.

Answers `ok` whatever happens, because a store that failed is a miss next time
and there is nothing a caller could usefully do about it. An unwritable
directory should not fail a worker that has a perfectly good image in memory.
""".
-spec store(binary() | undefined, wasm:snapshot(), term()) -> ok.
store(undefined, _Image, _Meta) ->
    ok;
store(Key, Image, _Meta) ->
    case dir() of
        undefined ->
            ok;
        Dir ->
            _ = filelib:ensure_path(Dir),
            Path = path(Dir, Key),
            _ = wasm:save_snapshot(Image, Path),
            %% **Here and nowhere else.** The directory only grows on a store,
            %% so that is the only moment it can need shrinking; there is no
            %% sweeper and a node that files nothing never evicts. The image
            %% just written is kept whatever its age, or a cap smaller than one
            %% image would file it and delete it in the same breath.
            ok = wasm_file_cache:sweep_and_evict(Dir, ?SUFFIX, max_bytes(), Path),
            ok
    end.

-doc """
Remove every image, and every half-written one.

For tests, and for a release that wants a clean start -- and for an operator
who has just lowered `max_snapshot_dir_bytes` and wants the directory to shrink
now rather than at the next store.
""".
-spec purge() -> ok.
purge() ->
    case dir() of
        undefined -> ok;
        Dir       -> wasm_file_cache:purge(Dir, ?SUFFIX)
    end.

-doc """
The cap in force, in bytes.

Resolved on **every store** through `application:get_env/3`, so a change is in
force from the next one and there is nothing cached to invalidate at boot. It
is reported rather than left implicit because a setting nobody can read back is
a setting nobody can tell is being used. `wasm_jit`'s `resolve_max_heap_words`
and `wasm_jit:compile_limits/0` exist for the same reason.

A value that cannot be a size -- negative, a float, an atom -- answers the
default and warns once. Taking it literally would mean a cap of `0` deleting
every image on the next store.
""".
-spec max_bytes() -> non_neg_integer().
max_bytes() ->
    case application:get_env(wasm, max_snapshot_dir_bytes, ?MAX_BYTES) of
        N when is_integer(N), N >= 0 -> N;
        Bad -> warn_once(Bad), ?MAX_BYTES
    end.

%% Once per node, because this is read on every store and a bad value would
%% otherwise fill a log with the same line.
warn_once(Bad) ->
    case persistent_term:get(?WARNED, false) of
        true ->
            ok;
        false ->
            persistent_term:put(?WARNED, true),
            logger:warning("wasm: max_snapshot_dir_bytes is ~p, which is not a "
                           "byte count; using ~p", [Bad, ?MAX_BYTES])
    end.

path(Dir, Key) ->
    filename:join(Dir, binary_to_list(binary:encode_hex(Key)) ++ ?SUFFIX).
