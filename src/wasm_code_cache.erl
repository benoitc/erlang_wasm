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
named for the hash of its key, and eviction is by total size, oldest first.
""".

-export([lookup/1, store/2, key/6, dir/0, purge/0]).

%% Beyond this the oldest entries go. Fifteen megabytes is one QuickJS, so this
%% holds a few dozen real modules.
-define(MAX_BYTES, 512 * 1024 * 1024).

-doc """
The artifact for this key, if there is one and it is readable.

Any failure is a miss. A cache that cannot be read is a slower start and never
an error, which is the same rule the rest of the tier follows: every refusal
means do the work.
""".
-spec lookup(binary()) -> {ok, binary()} | miss.
lookup(Key) ->
    case dir() of
        undefined -> miss;
        Dir ->
            File = path(Dir, Key),
            case file:read_file(File) of
                {ok, Bin} ->
                    %% Touch it, so eviction sees which entries are in use.
                    _ = file:change_time(File, calendar:local_time()),
                    {ok, Bin};
                {error, _} -> miss
            end
    end.

-doc """
Keep this artifact under this key.

Written to a temporary name and renamed, because a half-written `.beam` that a
later start reads is a crash rather than a miss, and rename is atomic on every
filesystem this runs on.
""".
-spec store(binary(), binary()) -> ok.
store(Key, Bin) ->
    case dir() of
        undefined -> ok;
        Dir ->
            _ = filelib:ensure_path(Dir),
            File = path(Dir, Key),
            %% `.tmp`, and not a suffix after `.beam`: `*.beam` does not match
            %% `X.beam.7`, so a temp named that way is invisible to both the
            %% sweep and the size cap and accumulates for ever.
            Tmp = filename:join(Dir, integer_to_list(erlang:unique_integer([positive]))
                                ++ ".tmp"),
            case file:write_file(Tmp, Bin) of
                ok ->
                    case file:rename(Tmp, File) of
                        ok -> ok;
                        %% Renaming can fail, and a temp nobody deletes is a
                        %% leak that no later run cleans up.
                        {error, _} -> _ = file:delete(Tmp), ok
                    end,
                    evict(Dir),
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
    case dir() of
        undefined -> ok;
        Dir ->
            _ = [file:delete(F) || F <- entries(Dir) ++ temps(Dir)],
            ok
    end.

%%% -------------------------------------------------------------- private ---

path(Dir, Key) ->
    filename:join(Dir, binary_to_list(binary:encode_hex(Key)) ++ ".beam").

%% Oldest first, until the total is under the cap. Reading an entry touches it,
%% so "oldest" means least recently used and not least recently written.
evict(Dir) ->
    sweep_temps(Dir),
    Files = [{filelib:last_modified(F), filelib:file_size(F), F} || F <- entries(Dir)],
    case lists:sum([S || {_, S, _} <- Files]) of
        Total when Total =< ?MAX_BYTES -> ok;
        Total -> drop(lists:sort(Files), Total)
    end.

entries(Dir) -> filelib:wildcard(filename:join(Dir, "*.beam")).
temps(Dir) -> filelib:wildcard(filename:join(Dir, "*.tmp")).

%% A temp older than an hour belongs to a process that is not coming back: a
%% node killed between the write and the rename leaves one, and nothing else
%% would ever remove it. An hour is far longer than any write takes and short
%% enough that a crash loop does not fill a disk.
sweep_temps(Dir) ->
    Cutoff = calendar:gregorian_seconds_to_datetime(
               calendar:datetime_to_gregorian_seconds(calendar:local_time()) - 3600),
    _ = [file:delete(F) || F <- temps(Dir),
                           filelib:last_modified(F) =/= 0,
                           filelib:last_modified(F) < Cutoff],
    ok.

drop([], _Total) -> ok;
drop(_Files, Total) when Total =< ?MAX_BYTES -> ok;
drop([{_T, Size, F} | Rest], Total) ->
    _ = file:delete(F),
    drop(Rest, Total - Size).
