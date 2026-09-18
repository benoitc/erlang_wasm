-module(restorebits).
-moduledoc """
What one `wasm:restore/3` spends, and on what.

Use this before and after any change to the restore path. `workerbench`'s
`phases` mode prices a restore from outside, where it is one interval of a
request bounded by adapter callbacks and inseparable from `deliver/3` and
`check_spec/1`. This goes inside it, so a change can be credited to the
operation it actually changed rather than to the bucket.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin \\
         -pa _build/test/lib/wasm/examples bench/paths/restorebits.erl
    erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \\
        -pa bench/paths -run restorebits main py_reactor <image.img>

The image is one a worker filed, so this needs no capture: a CPython capture is
ninety seconds and this arm is about a request.

## The parts are isolation measurements, not a partition

`whole` is one real `wasm:restore/3`. Everything above it is timed on its own,
and two of them are timed against a memory of this arm's own making rather than
the one a restore builds. **They do not sum to `whole` and are not meant to**:
`new` and the fills overlap, because what the fills exist to overwrite is what
`new` wrote. Subtracting them from each other would be the same arithmetic that
`PERF.md`'s QuickJS section exists to warn about.

What each one answers:

| | |
| --- | --- |
| `new` | `wasm_instance:new/3`: the chunks, the imports, and the active segments |
| `alloc` | the `atomics` for this image's pages, alone. A floor under `new` |
| `fill` | zeroing the gaps between the image's runs, over the image's own span |
| `runs` | writing the runs, the only part of a memory a restore has to write |
| `whole` | `wasm:restore/3` end to end |

The imports come from the adapter's own `snapshot_capability/1`, so the arm
restores against the declaration the image was captured under rather than one
written out here that can drift from it.
""".

-export([main/1]).

-include_lib("wasm/include/wasm.hrl").

-define(RUNS, 7).

main([Adapter, Img]) ->
    {ok, _} = application:ensure_all_started(wasm),
    io:format("# load average at start: ~s", [os:cmd("uptime")]),
    {Mod, Guest} = arm(Adapter),
    {ok, Artifact} = Mod:artifact(Guest),
    #{module := H, imports := ImportSet} = Mod:snapshot_capability(Artifact),
    {ok, M} = wasm_module_cache:get(H),
    {ok, S} = wasm:load_snapshot(Img, H),
    Bindings = maps:get(bindings, ImportSet),
    Opts = restore_opts(ImportSet, Guest),
    report_image(S),
    %% Discarded: the first restore carries the module cache, every lazily
    %% loaded host module and the first touch of the image's binaries.
    {ok, W} = restored(S, Bindings, Opts),
    ok = wasm:destroy(W),
    Rows = [one(S, M, Bindings, Opts) || _ <- lists:seq(1, ?RUNS)],
    io:format("~n~-10s ~12s ~12s~n", ["", "min us", "median us"]),
    [io:format("~-10s ~12w ~12w~n", [K, lists:min(C), med(C)])
     || K <- [new, alloc, fill, runs, whole],
        C <- [[maps:get(K, R) || R <- Rows]]],
    io:format("# load average at end: ~s", [os:cmd("uptime")]),
    init:stop().

%% One round. Each part is destroyed before the next is built, so no two of
%% them are holding forty megabytes at once.
one(S, M, Bindings, Opts) ->
    New = us(fun() ->
                 {ok, I} = wasm_instance:new(M, Bindings, instance_opts(Opts)),
                 ok = wasm:destroy(I)
             end),
    [#{pages := Pages, runs := Runs} | _] = maps:get(mems,
                                                     wasm_snapshot:to_parts(S)),
    Alloc = us(fun() -> {ok, _} = wasm_memory:new(Pages, Pages) end),
    {ok, Mem} = wasm_memory:new(Pages, Pages),
    Fill = us(fun() ->
                  [ok = wasm_memory:fill(Mem, At, 0, Len)
                   || {At, Len} <- gaps(Runs, 0, Pages * 65536, [])]
              end),
    Write = us(fun() ->
                   [ok = wasm_memory:store_bytes(Mem, Off, R) || {Off, R} <- Runs]
               end),
    Whole = us(fun() ->
                   {ok, I} = restored(S, Bindings, Opts),
                   ok = wasm:destroy(I)
               end),
    #{new => New, alloc => Alloc, fill => Fill, runs => Write, whole => Whole}.

%% `wasm_instance:new/3' is what a restore calls, and it must not be handed the
%% key: `wasm:restore/3' removes it before passing the rest on.
instance_opts(Opts) -> maps:remove(compatibility_key, Opts).

restored(S, Bindings, Opts) ->
    case wasm:restore(S, Bindings, Opts) of
        {ok, I}          -> {ok, I};
        {error, E}       -> exit({restore_failed, E});
        {error, E, Inst} -> ok = wasm:destroy(Inst), exit({restore_failed, E})
    end.

%% What `lay_runs/4' fills, derived the same way it derives it: everything the
%% runs do not cover, over the image's own span.
gaps([], At, End, Acc) when At < End -> lists:reverse([{At, End - At} | Acc]);
gaps([], _At, _End, Acc)             -> lists:reverse(Acc);
gaps([{Off, R} | Rest], At, End, Acc) ->
    Acc1 = case Off > At of
               true  -> [{At, Off - At} | Acc];
               false -> Acc
           end,
    gaps(Rest, Off + byte_size(R), End, Acc1).

report_image(S) ->
    P = wasm_snapshot:to_parts(S),
    Mems = maps:get(mems, P),
    Held = lists:sum([byte_size(R) || Mm <- Mems, {_, R} <- maps:get(runs, Mm)]),
    Span = lists:sum([maps:get(pages, Mm) * 65536 || Mm <- Mems]),
    io:format("# image ~w bytes held over ~w bytes of memory (~.1f%), "
              "~w runs, ~w table entries~n",
              [Held, Span, 100.0 * Held / Span,
               lists:sum([length(maps:get(runs, Mm)) || Mm <- Mems]),
               lists:sum([length(T) || T <- maps:get(tables, P)])]).

%% As `script_worker:restore_opts/1', plus the ceilings the guest needs: a
%% CPython image is past the default page budget and a restore that refused
%% would be measuring the refusal.
restore_opts(ImportSet, Guest) ->
    Base = #{fuel => infinity, timeout => infinity,
             max_memory_pages => maps:get(pages, Guest)},
    Hooks = case maps:get(snapshot_hooks, ImportSet, #{}) of
                Empty when map_size(Empty) =:= 0 -> Base;
                H -> Base#{snapshot_hooks => H}
            end,
    case maps:get(compatibility_key, ImportSet, undefined) of
        undefined -> Hooks;
        Key       -> Hooks#{compatibility_key => Key}
    end.

%% The same two guests `workerbench' knows, named the same way.
arm("py_reactor") ->
    {py_reactor_adapter,
     #{path => "test/fixtures/lang/py_reactor.wasm",
       lib => "test/fixtures/lang/py_reactor_lib", pages => 4096}};
arm("qjs_reactor") ->
    {qjs_reactor_adapter,
     #{path => "test/fixtures/lang/qjs_reactor.wasm", pages => 2048}}.

us(F) ->
    T0 = erlang:monotonic_time(microsecond),
    _ = F(),
    erlang:monotonic_time(microsecond) - T0.

med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).
