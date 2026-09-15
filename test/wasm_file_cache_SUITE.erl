-module(wasm_file_cache_SUITE).
-moduledoc """
The eviction policy both on-disk caches share.

It lived inside `wasm_code_cache` with a hardcoded 512 MB cap, which is why no
case had ever exercised it: reaching the cap meant writing half a gigabyte. The
cap is an argument now, so a case can reach it with a few hundred bytes, and
these are the first tests it has ever had.

No fixtures, no network, no application: this runs wherever `ct` does.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [nothing_is_dropped_under_the_cap,
     the_oldest_entry_goes_first,
     a_recently_read_entry_outlives_an_older_one,
     the_entry_just_written_is_never_dropped,
     a_stale_temp_is_swept,
     a_fresh_temp_is_left_alone,
     a_temp_is_neither_an_entry_nor_a_byte,
     purge_takes_temps_as_well_as_entries,
     a_directory_that_cannot_be_read_is_a_no_op].

-define(SUFFIX, ".img").

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    [{dir, Dir} | Config].

end_per_testcase(_TC, _Config) -> ok.

%%% ---------------------------------------------------------------- helpers ---

%% Named so the case can say which it expects back, and sized so a cap can be
%% expressed in whole entries.
write(Dir, Name, Bytes) ->
    Path = filename:join(Dir, Name ++ ?SUFFIX),
    ok = file:write_file(Path, binary:copy(~"x", Bytes)),
    Path.

%% Back-dated by whole seconds, because that is the resolution a filesystem
%% mtime has and a case that wrote three files in one second would be sorting
%% on nothing.
age(Path, Seconds) ->
    When = calendar:gregorian_seconds_to_datetime(
             calendar:datetime_to_gregorian_seconds(calendar:local_time())
             - Seconds),
    ok = file:change_time(Path, When).

names(Dir) ->
    lists:sort([filename:basename(F)
                || F <- wasm_file_cache:entries(Dir, ?SUFFIX)]).

evict(Dir, Max) -> wasm_file_cache:sweep_and_evict(Dir, ?SUFFIX, Max, undefined).

%%% ------------------------------------------------------------------ cases ---

nothing_is_dropped_under_the_cap(Config) ->
    Dir = ?config(dir, Config),
    _ = write(Dir, "a", 100),
    _ = write(Dir, "b", 100),
    ok = evict(Dir, 1000),
    ?assertEqual(["a.img", "b.img"], names(Dir)).

%% And it stops as soon as the total fits, rather than emptying the directory.
the_oldest_entry_goes_first(Config) ->
    Dir = ?config(dir, Config),
    age(write(Dir, "old", 100), 300),
    age(write(Dir, "mid", 100), 200),
    age(write(Dir, "new", 100), 100),
    ok = evict(Dir, 250),
    ?assertEqual(["mid.img", "new.img"], names(Dir)).

%% **The only case that proves the touch does anything.** Without it eviction
%% still stays under the cap and every other case here still passes; it just
%% throws away the entries being used. `wasm_snapshot_store:read/2` and
%% `wasm_code_cache:lookup/1` both call `touch/1` for this and nothing else.
a_recently_read_entry_outlives_an_older_one(Config) ->
    Dir = ?config(dir, Config),
    Older = write(Dir, "written_first", 100),
    _Newer = write(Dir, "written_second", 100),
    age(Older, 300),
    age(_Newer, 200),
    %% The one written first is read, which makes it the most recently *used*.
    ok = wasm_file_cache:touch(Older),
    ok = evict(Dir, 150),
    ?assertEqual(["written_first.img"], names(Dir)).

%% A cap smaller than one entry would otherwise file a thing and delete it in
%% the same breath, leaving the caller believing it had stored something.
the_entry_just_written_is_never_dropped(Config) ->
    Dir = ?config(dir, Config),
    age(write(Dir, "old", 100), 300),
    Written = write(Dir, "written", 500),
    ok = wasm_file_cache:sweep_and_evict(Dir, ?SUFFIX, 200, Written),
    ?assertEqual(["written.img"], names(Dir)).

a_stale_temp_is_swept(Config) ->
    Dir = ?config(dir, Config),
    Tmp = filename:join(Dir, "abc" ++ ?SUFFIX ++ ".7.tmp"),
    ok = file:write_file(Tmp, ~"half written"),
    age(Tmp, 7200),
    ok = evict(Dir, 1000),
    ?assertNot(filelib:is_regular(Tmp)).

%% One being written right now is not a leak, and deleting it would be.
a_fresh_temp_is_left_alone(Config) ->
    Dir = ?config(dir, Config),
    Tmp = filename:join(Dir, "abc" ++ ?SUFFIX ++ ".7.tmp"),
    ok = file:write_file(Tmp, ~"being written"),
    ok = evict(Dir, 1000),
    ?assert(filelib:is_regular(Tmp)).

%% `<hex>.img.<n>.tmp` ends in `.tmp`, so the entry glob must not match it: a
%% temp counted toward the total would evict real entries to make room for a
%% file that is about to be renamed anyway.
a_temp_is_neither_an_entry_nor_a_byte(Config) ->
    Dir = ?config(dir, Config),
    _ = write(Dir, "kept", 100),
    Tmp = filename:join(Dir, "kept" ++ ?SUFFIX ++ ".7.tmp"),
    ok = file:write_file(Tmp, binary:copy(~"x", 10_000)),
    %% A cap that the entry fits under and the temp's bytes would not.
    ok = evict(Dir, 200),
    ?assertEqual(["kept.img"], names(Dir)),
    ?assert(filelib:is_regular(Tmp)).

purge_takes_temps_as_well_as_entries(Config) ->
    Dir = ?config(dir, Config),
    _ = write(Dir, "a", 10),
    ok = file:write_file(filename:join(Dir, "a" ++ ?SUFFIX ++ ".7.tmp"), ~"t"),
    ok = wasm_file_cache:purge(Dir, ?SUFFIX),
    ?assertEqual([], filelib:wildcard(filename:join(Dir, "*"))).

%% Nothing here raises, so a directory that has been removed underneath is a
%% store that evicted nothing rather than a worker that failed to start.
a_directory_that_cannot_be_read_is_a_no_op(Config) ->
    Gone = filename:join(?config(dir, Config), "not-there"),
    ?assertEqual(ok, evict(Gone, 0)),
    ?assertEqual(ok, wasm_file_cache:purge(Gone, ?SUFFIX)),
    ?assertEqual([], wasm_file_cache:entries(Gone, ?SUFFIX)),
    ?assertEqual(ok, wasm_file_cache:touch(filename:join(Gone, "x.img"))).
