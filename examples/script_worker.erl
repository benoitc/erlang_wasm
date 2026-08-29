-module(script_worker).
-moduledoc """
Evaluating untrusted JavaScript that arrives at request time.

This is the **interpreted** shape. To run JavaScript, something has to
interpret JavaScript, and WebAssembly does not. So the module *is* an
interpreter, QuickJS compiled to wasm, and there are two levels:

```
  your code  ->  erlang_wasm  ->  qjs.wasm  ->  the script
                                  (1.8 MB)      (arrives per request)
```

Compare `plugin_worker`, where the logic is compiled ahead of time and there is
one level. Neither is the right answer; they answer different questions.

## When to use it

When the logic has to change without a deploy, or when the people writing it
will not compile anything. You pay for that in size and speed, measured on this
machine:

| | plugin_worker | script_worker |
| --- | ---: | ---: |
| module | 46 KB | 1.8 MB |
| compile, once | 14 ms | 300 ms |
| instantiate, per request | 4 us | 12 ms |
| trivial request | under 1 ms | 238 ms |

## Running one

```erlang
{ok, W} = script_worker:start_link("test/fixtures/lang/qjs.wasm"),
{ok, ~"3\\n"} = script_worker:eval(W, ~"print(1 + 2);"),
{error, timeout} = script_worker:eval(W, ~"for(;;){}").
```

Fetch the module with `scripts/fetch-qjs-fixture.sh`.

## How the script reaches the module

QuickJS expects a file, so each request gets a scratch directory of its own,
containing only the script, granted as the instance's only preopen and named in
`args`. The script therefore cannot read anything else, and two requests cannot
see each other's files, because neither directory outlives its request.

That path runs the whole WASI command model against a program that has never
heard of this runtime: argument marshalling, preopen discovery, `path_open`,
buffered output and `proc_exit`.
""".

-behaviour(gen_server).

-export([start_link/1, start_link/2, eval/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {module, timeout, dir}).

%% Generous next to a plugin's, because starting a JavaScript engine is a
%% quarter of a second before the script runs at all.
-define(DEFAULT_TIMEOUT, 10_000).

-spec start_link(file:filename_all()) -> {ok, pid()} | {error, term()}.
start_link(Path) -> start_link(Path, #{}).

-spec start_link(file:filename_all(), map()) -> {ok, pid()} | {error, term()}.
start_link(Path, Opts) -> gen_server:start_link(?MODULE, {Path, Opts}, []).

-doc "Evaluate a script and collect what it printed.".
-spec eval(pid(), binary()) -> {ok, binary()} | {error, term()}.
eval(W, Source) -> gen_server:call(W, {eval, Source}, infinity).

-spec stop(pid()) -> ok.
stop(W) -> gen_server:stop(W).

%%% ------------------------------------------------------------------ server ---

init({Path, Opts}) ->
    {ok, Bin} = file:read_file(Path),
    %% 300 ms for this module, paid once here rather than per request.
    case wasm:compile(Bin) of
        {error, E} ->
            {stop, E};
        {ok, Module} ->
            %% Per worker, not per OS process. `os:getpid()' is the same for
            %% every worker in the node, so a pool of them shared one scratch
            %% directory and overwrote each other's script between the write
            %% and the read.
            Dir = filename:join(maps:get(scratch, Opts, "/tmp"),
                                "script_worker_" ++ os:getpid() ++ "_" ++
                                    integer_to_list(
                                      erlang:unique_integer([positive]))),
            ok = filelib:ensure_path(Dir),
            {ok, #state{module = Module, dir = Dir,
                        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)}}
    end.

handle_call({eval, Source}, _From, State) ->
    {reply, run(State, Source), State}.

handle_cast(_, State) -> {noreply, State}.

terminate(_, #state{dir = Dir}) ->
    _ = file:del_dir_r(Dir),
    ok.

%%% ------------------------------------------------------------------- guts ---

run(#state{module = Module, timeout = Timeout, dir = Base}, Source) ->
    %% One directory per request, holding one file. It is the instance's only
    %% preopen and it is removed afterwards, so a script can neither read what
    %% another left nor leave anything for the next.
    Dir = filename:join(Base, integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    try
        ok = file:write_file(filename:join(Dir, "main.js"), Source),
        collect(Module, Dir, Timeout)
    after
        _ = file:del_dir_r(Dir)
    end.

collect(Module, Dir, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() -> Parent ! {Ref, once(Module, Dir)} end),
    receive
        {Ref, Reply} -> erlang:demonitor(Mon, [flush]), Reply;
        {'DOWN', Mon, process, Pid, Why} -> {error, {crashed, Why}}
    after Timeout ->
        %% A script that will not stop is stopped. `wasm:call/3' runs in the
        %% calling process, so only a process boundary makes this possible.
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 1000 -> ok end,
        {error, timeout}
    end.

once(Module, Dir) ->
    Self = self(),
    Sink = fun(D) -> Self ! {out, D}, ok end,
    Config = #{args => [~"qjs", ~"main.js"],
               env => #{},
               %% The only capability granted. No network: an absent `net' key
               %% is no network at all, however much the engine imports.
               dirs => [{~"/", Dir, read}],
               clocks => [monotonic, realtime],
               random => strong,
               stdout => Sink, stderr => Sink},
    case wasm:instantiate(Module, wasi_preview1:imports(Config)) of
        {error, E} ->
            {error, E};
        {ok, Inst} ->
            Result = wasm:call(Inst, ~"_start", []),
            Out = drain(<<>>),
            ok = wasm:destroy(Inst),
            case Result of
                {ok, _} -> {ok, Out};
                {error, E} ->
                    case wasi_preview1:exit_code(E) of
                        {ok, 0} -> {ok, Out};
                        {ok, Code} -> {error, {exit, Code, Out}};
                        error -> {error, E}
                    end
            end
    end.

drain(Acc) ->
    receive {out, D} -> drain(<<Acc/binary, D/binary>>)
    after 0 -> Acc
    end.
