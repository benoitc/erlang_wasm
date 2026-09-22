-module(wasm_recipe_SUITE).
-moduledoc """
Building a component from a recipe.

`steps/1` plans the build as data and `build/2` runs it through a caller's
runner, so most of this is checked without a toolchain: the plan is asserted
directly and the runner is a stub that records what it was asked to run. One
gated case builds a real component and skips when `cargo`/`wasm-tools` are
absent, the way the spec suites skip a missing upstream.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_steps_are_planned,
     build_runs_every_step_in_order,
     a_failing_step_stops_the_build,
     a_recipe_builds_a_real_component].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% The plan is cargo build, component new, validate, in that order, naming the
%% core module cargo writes and the component to produce.
the_steps_are_planned(_Config) ->
    Recipe = #{name => "echo", dir => "src/echo"},
    Core = "src/echo/target/wasm32-unknown-unknown/release/echo.wasm",
    Out = "src/echo/echo.component.wasm",
    ?assertEqual(
       [{"cargo", ["build", "--release", "--target", "wasm32-unknown-unknown"],
         "src/echo"},
        {"wasm-tools", ["component", "new", Core, "-o", Out], undefined},
        {"wasm-tools", ["validate", "--features", "component-model", Out],
         undefined}],
       wasm_recipe:steps(Recipe)).

%% build/2 runs every step, in order, and returns the component's path.
build_runs_every_step_in_order(_Config) ->
    Recipe = #{name => "echo", dir => "src/echo"},
    Self = self(),
    Run = fun(Step) -> Self ! {ran, Step}, ok end,
    ?assertEqual({ok, wasm_recipe:output(Recipe)}, wasm_recipe:build(Recipe, Run)),
    ?assertEqual(wasm_recipe:steps(Recipe), drain()).

%% A failing step stops the build: the error names the step, and the steps after
%% it never run.
a_failing_step_stops_the_build(_Config) ->
    Recipe = #{name => "echo", dir => "src/echo"},
    Self = self(),
    Run = fun(Step) ->
              Self ! {ran, Step},
              case Step of
                  {"wasm-tools", ["component" | _], _} -> {error, boom};
                  _ -> ok
              end
          end,
    ?assertMatch({error, {{"wasm-tools", ["component" | _], _}, boom}},
                 wasm_recipe:build(Recipe, Run)),
    %% cargo and the failing component-new ran; validate did not.
    ?assertEqual(2, length(drain())).

%% The real thing: build a committed fixture from a recipe and decode it. Skips
%% without the toolchain.
a_recipe_builds_a_real_component(Config) ->
    case wasm_recipe:toolchain_available() of
        false ->
            {skip, "cargo/wasm-tools not on the path"};
        true ->
            Priv = ?config(priv_dir, Config),
            Out = filename:join(Priv, "echo.component.wasm"),
            Recipe = #{name => "echo", dir => fixture_dir("echo"), out => Out},
            ?assertEqual({ok, Out}, wasm_recipe:build(Recipe)),
            {ok, Bin} = file:read_file(Out),
            ?assertMatch({ok, #{core := _, exports := _}}, wasm_component:decode(Bin))
    end.

%%% -------------------------------------------------------------- helpers ---

drain() ->
    receive {ran, Step} -> [Step | drain()] after 0 -> [] end.

fixture_dir(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", Name]).
