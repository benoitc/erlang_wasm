-module(wasm_snapshot_store).
-moduledoc """
A directory of snapshot images, keyed by what makes one valid.

Shaped on `wasm_code_cache`, which is the existing precedent for a build
artifact kept on disk and looked up by identity: a flat directory named by app
env, absent meaning off, one file per key, write to a temporary name and
rename. Read it for the reasoning about eviction and stale temporaries.

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

-export([dir/0, key/4, lookup/2, store/3, purge/0]).

-define(SUFFIX, ".img").

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
            %% Least-recently-used rather than least-recently-written, which is
            %% what makes a size cap evict the right thing later.
            _ = file:change_time(Path, calendar:local_time()),
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
            _ = wasm:save_snapshot(Image, path(Dir, Key)),
            ok
    end.

-doc "Remove every image. For tests, and for a release that wants a clean start.".
-spec purge() -> ok.
purge() ->
    case dir() of
        undefined -> ok;
        Dir ->
            _ = [file:delete(F)
                 || F <- filelib:wildcard(filename:join(Dir, "*" ++ ?SUFFIX))],
            ok
    end.

path(Dir, Key) ->
    filename:join(Dir, binary_to_list(binary:encode_hex(Key)) ++ ?SUFFIX).
