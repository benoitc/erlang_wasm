-module(wasm_file_cache).
-moduledoc """
A directory of files, bounded by total size, oldest first.

The policy behind both on-disk caches this runtime keeps: generated code in
`wasm_code_cache` and snapshot images in `wasm_snapshot_store`. It was written
once for the first and copied nowhere, which left the second growing without
bound; it lives here now so there is one copy and one set of cases.

Plain module code, called from whichever process is storing. No server, no
lock, no timer. **Eviction happens on a store and nowhere else**: a directory
only grows when something is written to it, so that is the only moment it can
need shrinking. A node that stores nothing never evicts, and a directory
already over its cap stays over it until the next store.

## What "oldest" means

Least recently **used**, not least recently written, because a reader calls
`touch/1` on a hit. That is the only thing separating the two, and it is worth
knowing that without it eviction still looks correct: it stays under the cap,
it just throws away the entries being used.

## What it does when something goes wrong

Nothing raises and nothing is reported. An unreadable directory answers no
entries and so evicts nothing. A failed delete is ignored, and `drop/2`
subtracts the size it expected to free either way, so a file that will not go
cannot make the loop spin. Two processes evicting at once both enumerate, both
delete, and the second delete fails with `enoent`: the result is over-eviction
rather than corruption, and over-eviction costs a recompile or a recapture.
""".

-export([sweep_and_evict/4, purge/2, touch/1, entries/2]).

%% A temp older than this belongs to a process that is not coming back: a node
%% killed between the write and the rename leaves one, and nothing else would
%% ever remove it. Far longer than any write takes, short enough that a crash
%% loop does not fill a disk.
-define(TEMP_AGE, 3600).

-doc """
Sweep stale temporaries, then drop oldest entries until the total fits.

`Suffix` selects the entries, `".img"` or `".beam"`. Temporaries are always
`*.tmp`, are swept by age, and are counted as neither entries nor bytes.

`Keep` is a path that must not be dropped whatever its age, which a caller
passes for the entry it has just written. Without it a store larger than the
whole cap writes a file and immediately deletes it, and the caller is left
believing it filed something.
""".
-spec sweep_and_evict(file:filename(), string(), non_neg_integer(),
                      file:filename() | undefined) -> ok.
sweep_and_evict(Dir, Suffix, Max, Keep) ->
    sweep_temps(Dir),
    Files = [{filelib:last_modified(F), filelib:file_size(F), F}
             || F <- entries(Dir, Suffix)],
    case lists:sum([S || {_, S, _} <- Files]) of
        Total when Total =< Max ->
            ok;
        Total ->
            %% `Keep` is out of the candidates but still in the total, so the
            %% others make room for it rather than being spared alongside it.
            drop([F || {_, _, P} = F <- lists:sort(Files), P =/= Keep],
                 Total, Max)
    end.

drop([], _Total, _Max) -> ok;
drop(_Files, Total, Max) when Total =< Max -> ok;
drop([{_T, Size, F} | Rest], Total, Max) ->
    %% The size is subtracted whether or not the delete worked. A file that
    %% cannot be removed would otherwise be retried for ever.
    _ = file:delete(F),
    drop(Rest, Total - Size, Max).

-doc "Every entry, oldest not first. `[]` for a directory that cannot be read.".
-spec entries(file:filename(), string()) -> [file:filename()].
entries(Dir, Suffix) -> filelib:wildcard(filename:join(Dir, "*" ++ Suffix)).

temps(Dir) -> filelib:wildcard(filename:join(Dir, "*.tmp")).

sweep_temps(Dir) ->
    Cutoff = calendar:gregorian_seconds_to_datetime(
               calendar:datetime_to_gregorian_seconds(calendar:local_time())
               - ?TEMP_AGE),
    _ = [file:delete(F) || F <- temps(Dir), stale(F, Cutoff)],
    ok.

%% `filelib:last_modified/1` answers the integer `0` for a file it cannot stat,
%% and `0 < {{Y,M,D},{H,Mi,S}}` is **true** in Erlang term order, so without
%% this an unreadable file is swept as though it were ancient.
stale(F, Cutoff) ->
    case filelib:last_modified(F) of
        0    -> false;
        When -> When < Cutoff
    end.

-doc "Remove every entry and every temporary. For tests, and for a clean start.".
-spec purge(file:filename(), string()) -> ok.
purge(Dir, Suffix) ->
    _ = [file:delete(F) || F <- entries(Dir, Suffix) ++ temps(Dir)],
    ok.

-doc """
Note that an entry was used, so eviction can tell which ones are.

The result is dropped: a read-only directory degrades to least-recently-written
rather than failing a lookup that otherwise worked.
""".
-spec touch(file:filename()) -> ok.
touch(Path) ->
    _ = file:change_time(Path, calendar:local_time()),
    ok.
