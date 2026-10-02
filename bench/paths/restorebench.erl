-module(restorebench).
-moduledoc """
What `wasm:restore/3` and `wasm:load_snapshot/2` take, per guest.

Use it to hold a change to the restore path or the image file against the
restore and snapshot load gates. The restore is timed from the call to
`{ok, Inst}`; the destroy that follows is outside the timed region, and so is
a garbage collection of the timing process before each sample, so one
sample's garbage is not collected inside the next.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
         bench/paths/reactorlib.erl bench/paths/restorebench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run restorebench main all 200 20 raw/restore.terms

Arguments: the guests (`all`, or a comma list of `py`, `qjs`, `lua`,
`plain`), restores per guest, snapshot loads per guest, and the file the raw
samples are appended to (`none` for no file). `plain` is a one-page module.

Images are read from `_build/imagecache`, captured and filed there by
`reactorlib` on the first run, so the first run of a tree is slow and is not
a sample. The restore is given the capture's own bindings, as `restorebits`
does, and the first restore of each guest is discarded.

Output is one line per guest and operation, minimum and median in
microseconds. **Read the load average first**; it is printed at the start and
the end and goes into the raw file.
""".

-export([main/1]).

-define(CACHE, "_build/imagecache").

main([Arms, N, L, Raw]) ->
    try run(arms(Arms), list_to_integer(N), list_to_integer(L), raw(Raw))
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

arms("all") -> [py, qjs, lua, plain];
arms(S) -> [list_to_atom(A) || A <- string:lexemes(S, ",")].

raw("none") -> none;
raw(P) -> P.

run(Arms, N, L, Raw) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    ok = reactorlib:write_raw(Raw, {meta, restorebench, Meta}),
    io:format("~-8s ~-14s ~6s ~12s ~12s~n",
              ["guest", "operation", "n", "min us", "median us"]),
    [arm(A, N, L, Raw) || A <- Arms],
    io:format("# ~s~n", [reactorlib:uptime_now()]),
    ok.

arm(Name, N, L, Raw) ->
    {ok, G} = reactorlib:guest(Name),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    Path = reactorlib:image_path(G, ?CACHE),
    {Bindings, Opts} = reactorlib:restore_args(G),
    {ok, W} = wasm:restore(Image, Bindings, Opts),
    ok = wasm:destroy(W),
    Rs = [restore_one(Image, Bindings, Opts) || _ <- lists:seq(1, N)],
    show(Name, restore, Rs),
    ok = reactorlib:write_raw(Raw, {restore, Name, Rs}),
    Ls = [load_one(G, Path) || _ <- lists:seq(1, L)],
    show(Name, load_snapshot, Ls),
    ok = reactorlib:write_raw(Raw, {load_snapshot, Name, Ls}),
    ok = wasm:release(Image).

restore_one(Image, Bindings, Opts) ->
    true = erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    {ok, I} = wasm:restore(Image, Bindings, Opts),
    T1 = erlang:monotonic_time(nanosecond),
    ok = wasm:destroy(I),
    (T1 - T0) / 1000.

%% The loaded image is released outside the timed region, so the next load is
%% not charged against a budget the last one still holds.
load_one(G, Path) ->
    true = erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    {ok, S} = reactorlib:load_image(G, Path),
    T1 = erlang:monotonic_time(nanosecond),
    ok = wasm:release(S),
    (T1 - T0) / 1000.

show(Name, Op, Us) ->
    io:format("~-8s ~-14s ~6w ~12.1f ~12.1f~n",
              [Name, Op, length(Us), lists:min(Us), reactorlib:med(Us)]).
