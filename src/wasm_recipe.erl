-module(wasm_recipe).
-moduledoc """
Build a component from a recipe.

A recipe is declarative data saying how to turn a source directory into a
component: the package name, where it is, the target, and where the component
goes. `steps/1` turns a recipe into the ordered build commands, and `build/1`
runs them, so the plan is inspectable before anything runs and the runner is
replaceable. This is what a caller (hornbeam building a node's images) drives
instead of a shell script.

A recipe is a map:

```erlang
#{name => "echo",
  dir  => "test/fixtures/component/echo",
  target => "wasm32-unknown-unknown",   % optional, this is the default
  out  => "echo.component.wasm"}        % optional, defaults beside dir
```

The steps run `cargo build`, `wasm-tools component new`, then
`wasm-tools validate`. Build it with the default runner, or pass your own to
`build/2` (to sandbox it, to log it, or to test it without a toolchain):

```erlang
{ok, Component} = wasm_recipe:build(Recipe).
```

Nothing here raises: a missing tool or a failing command is an `{error, _}`
value naming the step.
""".

-export([steps/1, output/1, build/1, build/2, toolchain_available/0]).

-export_type([recipe/0, step/0]).

-type recipe() :: #{name := string(), dir := string(),
                    target => string(), out => string()}.
-doc "A command to run: the program, its arguments, and the directory to run in.".
-type step() :: {Program :: string(), Args :: [string()],
                 Cwd :: string() | undefined}.

-define(DEFAULT_TARGET, "wasm32-unknown-unknown").

-doc "The ordered build commands for a recipe, as data. Runs nothing.".
-spec steps(recipe()) -> [step()].
steps(Recipe) ->
    #{name := Name, dir := Dir} = Recipe,
    Target = maps:get(target, Recipe, ?DEFAULT_TARGET),
    Out = output(Recipe),
    Core = filename:join([Dir, "target", Target, "release", Name ++ ".wasm"]),
    [{"cargo", ["build", "--release", "--target", Target], Dir},
     {"wasm-tools", ["component", "new", Core, "-o", Out], undefined},
     {"wasm-tools", ["validate", "--features", "component-model", Out], undefined}].

-doc "Where the recipe's component lands (its `out`, or beside `dir`).".
-spec output(recipe()) -> string().
output(Recipe) ->
    #{name := Name, dir := Dir} = Recipe,
    maps:get(out, Recipe, filename:join(Dir, Name ++ ".component.wasm")).

-doc "Build a recipe with the default runner. Returns the component's path.".
-spec build(recipe()) -> {ok, string()} | {error, term()}.
build(Recipe) ->
    build(Recipe, fun run_step/1).

-doc """
Build a recipe, running each step through `Run`. `Run` is
`fun(step()) -> ok | {error, term()}`; it stops at the first error and the rest
do not run. The default runner (`build/1`) shells out; a caller supplies its own
to sandbox, log or test the build.
""".
-spec build(recipe(), fun((step()) -> ok | {error, term()})) ->
          {ok, string()} | {error, term()}.
build(Recipe, Run) ->
    case run_all(steps(Recipe), Run) of
        ok             -> {ok, output(Recipe)};
        {error, _} = E -> E
    end.

-doc "Whether `cargo` and `wasm-tools` are both on the path.".
-spec toolchain_available() -> boolean().
toolchain_available() ->
    os:find_executable("cargo") =/= false
        andalso os:find_executable("wasm-tools") =/= false.

%%% -------------------------------------------------------------- internal ---

run_all([], _Run) ->
    ok;
run_all([Step | Rest], Run) ->
    case Run(Step) of
        ok             -> run_all(Rest, Run);
        {error, Reason} -> {error, {Step, Reason}}
    end.

%% Run one command, waiting for it. A non-zero exit or a missing program is an
%% error value, never a raise.
run_step({Program, Args, Cwd}) ->
    case os:find_executable(Program) of
        false ->
            {error, {not_found, Program}};
        Exe ->
            PortOpts = [exit_status, binary, stderr_to_stdout,
                        {args, Args} | cwd_opt(Cwd)],
            Port = open_port({spawn_executable, Exe}, PortOpts),
            collect(Port, [])
    end.

cwd_opt(undefined) -> [];
cwd_opt(Cwd)       -> [{cd, Cwd}].

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Code}} ->
            {error, {exit, Code, iolist_to_binary(lists:reverse(Acc))}}
    end.
