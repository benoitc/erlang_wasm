-module(instbench).
-moduledoc """
What a fresh `wasm:instantiate/3` costs, for the three ways a module reaches
it.

Use it to hold a change to instantiation or data segment initialisation
against the fresh instantiate gate. Each iteration instantiates and destroys;
the figure is the minimum over five rounds of N iterations, in microseconds
per instantiate and destroy, as `pathbench` reports its `inst_` arms.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
        bench/paths/instbench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run instbench main const

Arms:

- `const`: the Rust plugin (`test/fixtures/plugin/plugin.wasm`, 17 pages,
  constant-offset data segments) loaded through the module cache with
  `wasm:load/1`.
- `gget`: `inst_gget.wasm` beside this file, 17 pages and one 8 KiB data
  segment placed at `(global.get $base)` of an imported global, loaded with
  `wasm:load/1`. Its text is `inst_gget.wat`.
- `uncached`: the plugin as the `#module{}` `wasm:compile/1` answers, which the
  module cache never saw.
""".
-export([main/1]).

main([Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Load = string:trim(os:cmd("uptime | sed 's/.*averages*: //'")),
    {M, Im, N} = setup(list_to_atom(Arm)),
    F = fun() ->
                {ok, I} = wasm:instantiate(M, Im, #{}),
                ok = wasm:destroy(I)
        end,
    _ = loop(50, F),
    Ts = [begin
              true = erlang:garbage_collect(),
              {T, _} = timer:tc(fun() -> loop(N, F) end),
              T / N
          end || _ <- lists:seq(1, 5)],
    io:format("~s\t~.2f us\tn=~p rounds=~p\tload=~s~n",
              [Arm, lists:min(Ts), N, [round(T * 100) / 100 || T <- Ts],
               Load]),
    halt().

setup(const) ->
    {ok, M} = wasm:load(plugin()),
    {M, wasi_preview1:imports(#{}), 2000};
setup(gget) ->
    {ok, B} = file:read_file("bench/paths/inst_gget.wasm"),
    {ok, M} = wasm:load(B),
    {M, #{{~"env", ~"base"} => 4096}, 2000};
setup(uncached) ->
    {ok, M} = wasm:compile(plugin()),
    {M, wasi_preview1:imports(#{}), 2000}.

plugin() ->
    {ok, B} = file:read_file("test/fixtures/plugin/plugin.wasm"),
    B.

loop(0, _F) -> ok;
loop(N, F) -> _ = F(), loop(N - 1, F).
