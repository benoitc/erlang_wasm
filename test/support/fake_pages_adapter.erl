-module(fake_pages_adapter).
-moduledoc """
A snapshot-capable adapter whose request names the pages it writes.

`restore_ahead` learns which 4 KiB pages requests write and copies them out
of the image while the worker is idle. A case holding that to account needs
to know the write set exactly, so the guest here writes nothing of its own:
`#{pages => [P]}` touches each page `P` of `pages.wasm` once, and nothing
else is written.

What a case reads back, in the result beside `values`:

- `private_at_start`: the pages already private when the request's instance
  was handed over, which is to say the ones prepared for it;
- `faults`, when the request carries `count => true`: the calls to
  `wasm_memory:fault/2` between the handover and the result, counted with
  call-count tracing, so only this request's first writes.

A request carrying `hold => {Pid, N}` installs a hook in the runner that
stops at the `N`th page the runner prepares after this request, says
`{preparing, Runner}` to `Pid` and waits for `go`.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).

-define(VERSION, ~"fake-pages-1").
-define(FAULT, {wasm_memory, fault, 2}).
-define(HOOK, {wasm_memory, fault_hook}).
-define(COUNT, {?MODULE, count}).
-define(AT_START, {?MODULE, private_at_start}).

artifact(_Opts) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                          "pages.wasm"]),
    {ok, Bytes} = file:read_file(Path),
    case wasm:load(Bytes) of
        {ok, M}    -> {ok, #{module => M}};
        {error, E} -> {error, wasm_worker_error:runtime(E)}
    end.

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 50, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map",
                                      #{})}.

%% Runs in the runner, before the restore, so what it leaves in the process
%% dictionary is there for `post_restore' and `decode/2'.
prepare(Request, #{module := M}, _Env) ->
    put(?COUNT, maps:get(count, Request, false)),
    ok = hold(maps:get(hold, Request, undefined)),
    Touch = [{call, ~"touch", [P]} || P <- maps:get(pages, Request, [])],
    {ok, #{mode => reactor, module => M, imports => import_set(),
           invoke => Touch ++ [{call, ~"ready", []}]},
     undefined}.

hold(undefined) ->
    ok;
hold({Pid, N}) ->
    put(?HOOK, fun(prepare) -> at_prepare(Pid, N);
                  (_Point) -> ok
               end),
    put({?MODULE, seen}, 0),
    ok.

at_prepare(Pid, N) ->
    Seen = get({?MODULE, seen}) + 1,
    put({?MODULE, seen}, Seen),
    case Seen of
        N ->
            _ = erase(?HOOK),
            Pid ! {preparing, self()},
            receive go -> ok end;
        _ ->
            ok
    end.

import_set() ->
    #{bindings => #{}, snapshot_hooks => #{}, compatibility_key => ?VERSION}.

decode(#{outcome := returned, values := Values}, _State) ->
    Faults = case erase(?COUNT) of
                 true ->
                     {call_count, N} = erlang:trace_info(?FAULT, call_count),
                     _ = erlang:trace_pattern(?FAULT, false, [call_count]),
                     #{faults => N};
                 _ ->
                     #{}
             end,
    {ok, Faults#{values => Values, private_at_start => erase(?AT_START)}};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"exited", #{code => Code})}.

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [typed_args],
      result_channels => [typed_result],
      snapshots => #{version => ?VERSION},
      wasi => false}.

snapshot_capability(#{module := M}) ->
    #{version => ?VERSION,
      module => M,
      imports => import_set(),
      init => [{call, ~"init", []}],
      validate => fun(_Inst) -> ok end,
      post_restore => fun post_restore/2}.

%% The instance as the request receives it: what is private already was
%% prepared, and counting starts here so the preparation is not counted.
post_restore(Inst, _Ctx) ->
    put(?AT_START, wasm_memory:written_pages(wasm_instance:memory(Inst, 0))),
    _ = get(?COUNT) =:= true
        andalso erlang:trace_pattern(?FAULT, true, [call_count]),
    ok.

conformance_fixtures(_Artifact) ->
    #{base => #{echo => #{}, failure => #{pages => [-1]},
                runaway => #{}, state_change => #{}},
      by_capability => #{}}.

classify({ok, _}, _State)    -> continue;
classify({error, _}, _State) -> {stop, trapped}.
