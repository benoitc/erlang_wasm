-module(reactorlib).
-moduledoc """
Reactor images and one request against them, without a worker.

`restorebench`, `capturebench` and `densitybench` need the same three
things: the guests named the same way, an image of each, and a request served
from an image by the caller's own process. A worker serves a request in a
runner it spawns, behind a guardian, so what it holds cannot be counted per
instance. This builds the request the runner builds, from the adapter's own
callbacks, in the process that asks.

    {ok, G} = reactorlib:guest(py),
    {ok, Image} = reactorlib:image(G, "_build/imagecache"),
    {ok, Result, Inst} = reactorlib:request(G, Image),
    ok = reactorlib:finish(Inst).

## What `request/2` does, in the runner's order

`requirements/2`, then `prepare/3` with an environment built here (one
read-only mount in a private directory, the three channels, a stage function
that writes into that directory), then `wasm:restore/3` with the request's
bindings and the import set's hooks and key, then the adapter's
`post_restore`, then each invocation followed by `classify/2`, then the
channels read and `decode/2`. The instance is handed back alive, so a caller
can hold it.

What it leaves out is the worker: no guardian, no reaper, no keeper
reservation for recycled memory, no runner heap floor. The adapter callbacks
and the restore are the ones a worker runs.

## The images

Each image is captured once by instantiating the adapter's
`snapshot_capability/1` declaration, running its `init` list and its
`validate`, and filed with `wasm:save_snapshot/2`. Later runs read it back
with `wasm:load_snapshot/2`. A file this build cannot read is captured again,
so a baseline and a candidate tree each keep their own.

`plain` is `test/fixtures/snapshot/reactor.wasm`, a one-page module whose
`init` writes its memory and whose `handle` reads it.
""".

-export([guest/1, guests/0, image/2, image_path/2, load_image/2,
         capture_ready/1, snapshot_of/2, worker_opts/2, restore_args/1,
         request/2, finish/1,
         expected/1, page_limit/1, meta/0, uptime_now/0, med/1,
         write_raw/2]).

-define(LANG, "test/fixtures/lang/").
-define(LIMITS, #{fuel => infinity, timeout => infinity,
                  max_memory_pages => 65536}).

%%% --------------------------------------------------------------- guests ---

-doc "Every guest this knows, in the order the arms run them.".
guests() -> [py, qjs, lua, plain].

-doc """
A guest: its adapter, artifact, capability, request and expected result.

`py_entry` is CPython with an entry set at capture, so a request carries no
source and calls `call`.
""".
guest(Name) ->
    case spec(Name) of
        {plain, Path} ->
            {ok, Bytes} = file:read_file(Path),
            {ok, H} = wasm:load(Bytes),
            {ok, #{name => plain, module => H}};
        {Adapter, Opts, Request} ->
            {ok, Artifact} = Adapter:artifact(Opts),
            Cap = Adapter:snapshot_capability(Artifact),
            {ok, #{name => Name, adapter => Adapter, artifact => Artifact,
                   cap => Cap, request => Request,
                   module => maps:get(module, Cap)}}
    end.

spec(py) ->
    {wasm_python,
     #{path => ?LANG "py_reactor.wasm", lib => ?LANG "py_reactor_lib"},
     #{source => ~"def main(c):\n    return {'doubled': c['n'] * 2}\n",
       context => #{~"n" => 21}}};
spec(py_entry) ->
    {wasm_python,
     #{path => ?LANG "py_reactor.wasm", lib => ?LANG "py_reactor_lib",
       entry => <<"import worker\nworker.set_entry(lambda c: "
                   "{'doubled': c['n'] * 2})\n">>},
     #{context => #{~"n" => 21}}};
spec(qjs) ->
    {wasm_javascript, #{path => ?LANG "qjs_reactor.wasm"},
     #{source => ~"export function main(c) { return {doubled: c.n * 2}; }",
       context => #{~"n" => 21}}};
spec(lua) ->
    {wasm_lua, #{path => ?LANG "lua_reactor.wasm"},
     #{source => ~"function main(c) return {doubled = c.n * 2} end",
       context => #{~"n" => 21}}};
spec(plain) ->
    {plain, "test/fixtures/snapshot/reactor.wasm"}.

-doc """
The adapter and the `wasm_script_worker:start_link/2` options for this guest.

The same on every tree: the stock adapter's own `limits()` where it has one,
`timeout` set to `Timeout`, and for CPython the capture floor `docs/python.md`
pairs with a 32 M-word ceiling, which takes a capture from ninety seconds to
about twenty. No `recycle_idle`, no `restore_ahead`: the caller adds what it
means to vary.
""".
worker_opts(Name, Timeout) ->
    {Adapter, Opts, _Request} = spec(Name),
    Limits = case Adapter of
                 wasm_python ->
                     maps:merge(wasm_python:limits(),
                                #{max_heap_words => 32 * 1024 * 1024});
                 wasm_lua ->
                     wasm_lua:limits();
                 wasm_javascript ->
                     #{}
             end,
    Extra = case Adapter of
                wasm_python -> #{capture_min_heap_words => 2_000_000,
                                 capture_timeout => 300_000};
                _ -> #{}
            end,
    {Adapter, maps:merge(Opts#{root => scratch,
                               limits => Limits#{timeout => Timeout}},
                         Extra)}.

-doc "What every request of this guest must answer.".
expected(#{name := plain}) -> {ok, [1235]};
expected(_) -> #{~"doubled" => 42}.

%%% --------------------------------------------------------------- images ---

-doc """
The guest's image, read from `Dir` or captured and filed there.

The answer is held by the calling process.
""".
image(G, Dir) ->
    ok = filelib:ensure_path(Dir),
    Path = image_path(G, Dir),
    case load_image(G, Path) of
        {ok, Image} ->
            {ok, Image};
        {error, _} ->
            {ok, Image} = capture(G),
            ok = wasm:save_snapshot(Image, Path),
            {ok, Image}
    end.

-doc "Where `image/2` files this guest's image under `Dir`.".
image_path(G, Dir) ->
    filename:join(Dir, atom_to_list(maps:get(name, G)) ++ ".img").

-doc "`wasm:load_snapshot/2` for this guest's module, and nothing else.".
load_image(#{module := H}, Path) -> wasm:load_snapshot(Path, H).

%% In a child with a heap floor, because CPython's `init()' is ninety seconds
%% without one and seventeen with it. The parent acquires before the child
%% exits: the capturer is the image's first holder.
capture(G) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} =
        spawn_opt(fun() ->
                          {ok, Inst} = capture_ready(G),
                          R = snapshot_of(G, Inst),
                          ok = wasm:destroy(Inst),
                          Parent ! {Ref, R},
                          receive {Ref, done} -> ok end
                  end, [monitor, {min_heap_size, 2_000_000}]),
    receive
        {Ref, {ok, Image}} ->
            ok = wasm:acquire(Image),
            Pid ! {Ref, done},
            receive {'DOWN', Mon, process, Pid, _} -> ok end,
            {ok, Image};
        {Ref, Other} ->
            exit({capture_failed, Other});
        {'DOWN', Mon, process, Pid, Why} ->
            exit({capture_died, Why})
    end.

-doc """
An instance at the point a capture would take it: instantiated under the
declaration, `init` run and `validate` passed. `snapshot_of/2` takes it.
""".
capture_ready(#{name := plain, module := H}) ->
    {ok, Inst} = wasm:instantiate(H, #{}, plain_opts()),
    {ok, []} = wasm:call(Inst, ~"init", []),
    {ok, Inst};
capture_ready(#{cap := Cap}) ->
    #{module := M, imports := IS, init := Init, validate := Validate} = Cap,
    Unbounded = #{fuel => infinity, timeout => infinity},
    Opts = maps:merge(Unbounded#{snapshotable => true}, restore_opts(IS)),
    {ok, Inst} = wasm:instantiate(M, maps:get(bindings, IS), Opts),
    [{ok, _} = wasm:call(Inst, Name, Args, Unbounded)
     || {call, Name, Args} <- Init],
    ok = Validate(Inst),
    {ok, Inst}.

plain_opts() ->
    #{snapshotable => true, snapshot_hooks => #{~"env" => stateless}}.

-doc "`wasm:snapshot/2` with the options a worker passes it.".
snapshot_of(#{name := plain}, Inst) ->
    wasm:snapshot(Inst, #{});
snapshot_of(#{cap := #{version := V, imports := IS}}, Inst) ->
    Keys = maps:with([compatibility_key], restore_opts(IS)),
    wasm:snapshot(Inst, Keys#{version => V}).

-doc """
The bindings and options a restore of this guest's image is given when only
the restore is being timed: the capture's own bindings, as `restorebits` does.
""".
restore_args(#{name := plain}) ->
    {#{}, #{}};
restore_args(#{cap := #{imports := IS}}) ->
    {maps:get(bindings, IS), maps:merge(?LIMITS, restore_opts(IS))}.

%% As `wasm_script_worker:restore_opts/1'.
restore_opts(IS) ->
    Base = case maps:get(snapshot_hooks, IS, #{}) of
               Empty when map_size(Empty) =:= 0 -> #{};
               Hooks -> #{snapshot_hooks => Hooks}
           end,
    case maps:get(compatibility_key, IS, undefined) of
        undefined -> Base;
        Key       -> Base#{compatibility_key => Key}
    end.

%%% -------------------------------------------------------------- request ---

-doc """
Restore `Image` and serve the guest's request from it, in this process.

`{ok, Result, Inst}` with the instance alive, `{error, restore, E}` when the
restore refused, or `{error, Stage, Term}` for anything after it, with the
instance already destroyed.
""".
request(#{name := plain} = G, Image) ->
    case wasm:restore(Image, #{}, #{}) of
        {error, E} -> {error, restore, E};
        {ok, Inst} -> answered(G, Inst, wasm:call(Inst, ~"handle", []))
    end;
request(G, Image) ->
    #{adapter := A, artifact := Art, cap := Cap, request := Req} = G,
    {ok, _Reqs} = A:requirements(Req, Art),
    Dir = private_dir(),
    Chans = #{stdout => channel(stdout), stderr => channel(stderr),
              result => channel(result)},
    Env = #{mounts => #{ro => #{guest_path => ~"/", host_dir => Dir,
                                mode => read}},
            channels => Chans, deadline => infinity, limits => ?LIMITS,
            cleanup => #{register => fun(_) -> {ok, make_ref()} end,
                         withdraw => fun(_) -> ok end},
            stage => fun(ro, Path, Data) ->
                             file:write_file(filename:join(Dir, Path), Data)
                     end},
    {ok, #{imports := IS, invoke := Invoke}, AState} = A:prepare(Req, Art, Env),
    Opts = maps:merge(?LIMITS, restore_opts(IS)),
    R = case wasm:restore(Image, maps:get(bindings, IS), Opts) of
            {error, E} ->
                {error, restore, E};
            {ok, Inst} ->
                served(A, Cap, Image, Inst, Invoke, AState, Chans)
        end,
    _ = file:del_dir_r(Dir),
    [ets:delete(T) || {channel, _, T, _, _} <- maps:values(Chans)],
    R.

served(A, #{post_restore := F}, Image, Inst, Invoke, AState, Chans) ->
    #{module := M, version := V} = wasm:snapshot_info(Image),
    case F(Inst, #{module => M, version => V}) of
        ok ->
            Exec = invoke(Invoke, Inst, A, AState),
            Out = A:decode(executed(Exec, Chans), AState),
            case Out of
                {ok, #{result := Result}} -> {ok, Result, Inst};
                Other -> ok = wasm:destroy(Inst), {error, decode, Other}
            end;
        Refused ->
            ok = wasm:destroy(Inst),
            {error, post_restore, Refused}
    end.

answered(G, Inst, R) ->
    case R =:= expected(G) of
        true  -> {ok, R, Inst};
        false -> ok = wasm:destroy(Inst), {error, call, R}
    end.

%% As the runner's `invoke_loop/5'.
invoke([{call, Name, Args} | Rest], Inst, A, AState) ->
    IR = wasm:call(Inst, Name, Args, ?LIMITS),
    case {A:classify(IR, AState), Rest, IR} of
        {continue, [], {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {continue, [], {error, E}} -> {trapped, [], undefined, E};
        {continue, _, _} -> invoke(Rest, Inst, A, AState);
        {{stop, returned}, _, {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {{stop, {exited, C}}, _, {ok, Vs}} -> {exited, Vs, C, undefined};
        {{stop, {exited, C}}, _, {error, E}} -> {exited, [], C, E};
        {_, _, {ok, Vs}} -> {trapped, Vs, undefined, undefined};
        {_, _, {error, E}} -> {trapped, [], undefined, E}
    end.

executed({Outcome, Values, Exit, Err}, Chans) ->
    Read = fun(K) -> read_channel(maps:get(K, Chans)) end,
    {Out, TO} = Read(stdout),
    {Er, TE} = Read(stderr),
    {Res, TR} = Read(result),
    #{outcome => Outcome, values => Values, exit => Exit, error => Err,
      channels => #{stdout => Out, stderr => Er, result => Res},
      truncated => #{stdout => TO, stderr => TE, result => TR}}.

%% `wasm_worker_adapter:channel()', the documented shape, with the kernel's
%% one-mebibyte bound.
channel(Which) ->
    {channel, Which, ets:new(reactorlib_channel, [ordered_set, public]),
     atomics:new(1, []), 1_048_576}.

read_channel({channel, _, Tab, Counter, Limit}) ->
    {iolist_to_binary([D || {_, D} <- ets:tab2list(Tab)]),
     atomics:get(Counter, 1) > Limit}.

private_dir() ->
    Dir = filename:join([filename:basedir(user_cache, "erlang_wasm_bench"),
                         "req-" ++ integer_to_list(
                                     erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

-doc "Destroy an instance a request handed back.".
finish(Inst) -> wasm:destroy(Inst).

%%% ---------------------------------------------------------------- misc ---

-doc """
Set `page_limit` before the application starts, and check it took.

The budget is read once, when the engine first makes its counters, so a value
set after that is ignored without a word.
""".
page_limit(N) ->
    _ = application:load(wasm),
    ok = application:set_env(wasm, page_limit, N),
    {ok, _} = application:ensure_all_started(wasm),
    N = wasm_engine:page_limit(),
    ok.

-doc "What every raw file starts with: the box, the VM and the load.".
meta() ->
    #{uptime => string:trim(os:cmd("uptime")),
      otp => erlang:system_info(otp_release),
      schedulers => {erlang:system_info(schedulers),
                     erlang:system_info(schedulers_online)},
      wasm_vsn => case application:get_key(wasm, vsn) of
                      {ok, V} -> V;
                      undefined -> undefined
                  end,
      cwd => element(2, file:get_cwd()),
      fixtures => [{F, fixture_hash(F)}
                   || F <- [?LANG "py_reactor.wasm", ?LANG "qjs_reactor.wasm",
                            ?LANG "lua_reactor.wasm",
                            "test/fixtures/snapshot/reactor.wasm"]]}.

fixture_hash(F) ->
    case file:read_file(F) of
        {ok, B} -> binary:encode_hex(crypto:hash(sha256, B), lowercase);
        {error, _} = E -> E
    end.

uptime_now() -> string:trim(os:cmd("uptime")).

med([]) -> undefined;
med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).

-doc "Append `Term` to the raw sample file, one term per line.".
write_raw(none, _Term) -> ok;
write_raw(Path, Term) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, io_lib:format("~0p.~n", [Term]), [append]).
