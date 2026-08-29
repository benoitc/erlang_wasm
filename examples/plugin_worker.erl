-module(plugin_worker).
-moduledoc """
Running untrusted plugin logic that was compiled to WebAssembly.

This is the **compiled** shape, and the one most applications want. The logic
is fixed at build time, `erlang_wasm` interprets it directly, and there is one
level of interpretation:

```
  your code  ->  erlang_wasm  ->  plugin.wasm   (46 KB)
```

Compare `script_worker`, which ships an interpreter inside the module so that
logic can arrive as text at request time, and pays for it.

## When to use it

When the logic changes at deploy time rather than per request, and you can ask
whoever writes it to compile. It is smaller, faster to instantiate and faster
to run than any scripting arrangement, and it is the only one where the module
is small enough to instantiate per request without thinking about it.

## Running one

```erlang
{ok, W} = plugin_worker:start_link("test/fixtures/plugin/plugin.wasm"),
{ok, ~"user@example.com"} = plugin_worker:normalise(W, ~"  User@Example.COM  "),
{error, invalid} = plugin_worker:normalise(W, ~"nonsense"),
{error, timeout} = plugin_worker:hang(W).
```

## What bounds it

Every request gets a fresh instance, so nothing carries over, and a timeout
kills the worker rather than waiting for it. Those two together are what make
the plugin untrusted rather than merely separate: see `docs/security.md` for
what they do and do not cover.

The module is decoded and validated **once**, with `wasm:compile/1`, and every
request instantiates from that. Decoding per request would be the expensive
part, and instantiating is microseconds.
""".

-behaviour(gen_server).

-export([start_link/1, start_link/2, normalise/2, hang/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {module, timeout}).

-define(DEFAULT_TIMEOUT, 1000).

-doc "Load a plugin and start a worker for it.".
-spec start_link(file:filename_all()) -> {ok, pid()} | {error, term()}.
start_link(Path) -> start_link(Path, #{}).

-spec start_link(file:filename_all(), map()) -> {ok, pid()} | {error, term()}.
start_link(Path, Opts) -> gen_server:start_link(?MODULE, {Path, Opts}, []).

-doc """
Normalise a record, or find out it is not one this plugin accepts.

The plugin gets the bytes and nothing else: no filesystem, no clock, no
network. Its only imports are the four its standard library insists on.
""".
-spec normalise(pid(), binary()) -> {ok, binary()} | {error, term()}.
normalise(W, Record) -> gen_server:call(W, {normalise, Record}, infinity).

-doc "Call the plugin's non-terminating export, to watch the timeout work.".
-spec hang(pid()) -> {error, timeout}.
hang(W) -> gen_server:call(W, hang, infinity).

-spec stop(pid()) -> ok.
stop(W) -> gen_server:stop(W).

%%% ------------------------------------------------------------------ server ---

init({Path, Opts}) ->
    {ok, Bin} = file:read_file(Path),
    %% Decode and validate once. This is the expensive half and it does not
    %% depend on the request.
    case wasm:compile(Bin) of
        {error, E} -> {stop, E};
        {ok, Module} ->
            {ok, #state{module = Module,
                        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)}}
    end.

handle_call({normalise, Record}, _From, State) ->
    {reply, in_fresh_instance(State, fun(I) -> do_normalise(I, Record) end), State};
handle_call(hang, _From, State) ->
    {reply, in_fresh_instance(State, fun(I) -> wasm:call(I, ~"spin", []) end), State}.

handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

%%% ------------------------------------------------------------------- guts ---

%% A fresh instance per request, in a process of its own so a timeout can kill
%% it. `wasm:call/3' runs in the calling process and cannot be interrupted, so
%% the process boundary is what makes the timeout enforceable rather than
%% advisory. That is the same argument `docs/worker.md' makes.
in_fresh_instance(#state{module = Module, timeout = Timeout}, Fun) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(
        fun() ->
            Imports = wasi:imports(#{args => [~"plugin"]}),
            case wasm:instantiate(Module, Imports, #{fuel => 50_000_000}) of
                {error, E} ->
                    Parent ! {Ref, {error, E}};
                {ok, Inst} ->
                    Parent ! {Ref, Fun(Inst)},
                    ok = wasm:destroy(Inst)
            end
        end),
    receive
        {Ref, Reply} ->
            erlang:demonitor(Mon, [flush]),
            Reply;
        {'DOWN', Mon, process, Pid, Why} ->
            {error, {crashed, Why}}
    after Timeout ->
        %% Killing the process releases the instance's pages with it.
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 1000 -> ok end,
        {error, timeout}
    end.

do_normalise(Inst, Record) ->
    {ok, [Buf]} = wasm:call(Inst, ~"buffer", []),
    {ok, [Cap]} = wasm:call(Inst, ~"capacity", []),
    case byte_size(Record) > Cap of
        true ->
            {error, too_long};
        false ->
            ok = wasm:write_memory(Inst, Buf, Record),
            case wasm:call(Inst, ~"normalise", [byte_size(Record)]) of
                {ok, [Len]} when Len >= 0 ->
                    wasm:read_memory(Inst, Buf, Len);
                {ok, [_]} ->
                    {error, invalid};
                Other ->
                    Other
            end
    end.
