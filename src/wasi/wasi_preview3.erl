-module(wasi_preview3).
-moduledoc """
The WASI 0.3 host: `wasi:cli`, `wasi:clocks`, `wasi:random`, and
`wasi:filesystem`, `wasi:sockets` and `wasi:http` through
`wasi_p3_filesystem`, `wasi_p3_sockets` and `wasi_p3_http`.

WASI 0.3 replaces `wasi:io`'s streams and pollables with the Component Model's
own `stream<T>`, `future<T>` and `async func`. Each interface here is keyed
`Interface@0.3`, so it serves every `0.3.x` import and never answers a 0.2 one
(see `wasm_component`'s import resolution). A 0.3 program built through the
wasip1 adapter imports both versions, so `command/1` is the 0.2 host and this
one together, and `run_command/3` runs a 0.2 or a 0.3 command.

```erlang
{ok, #{stdout := Out, exit_code := 0}} =
    wasi_preview3:run_command(Bin, <<>>, #{args => [~"prog"]}).
```

- stdout and stderr: `write-via-stream` takes the guest's stream and passes
  every write to the sink as it happens (`wasm_async:host_sink/2`).
- stdin: `read-via-stream` gives the guest a stream that a producer fills with
  the input.
- `wait-for` and `wait-until` are async imports: the guest's task waits on a
  timer while the instance's other tasks run.
""".

-export([command/1, run_command/3, run_serve/3, cli/1, clocks/0, random/0]).

-define(STDIO_RESULT, {result, none, {enum, [~"io", ~"illegal-byte-sequence", ~"pipe"]}}).

-type host() :: #{{binary(), binary()} => term()}.

-doc """
Every import a `wasi:cli/command` needs at 0.2 and at 0.3: the 0.2 host of
`wasi_preview2:command/1` with cli, clocks and random at 0.3 beside it. `Opts`
is as for `wasi_preview2:command/1`.
""".
-spec command(map()) -> host().
command(Opts) ->
    lists:foldl(fun maps:merge/2, wasi_preview2:command(Opts),
                [cli(Opts), clocks(), random(),
                 wasi_p3_filesystem:filesystem(
                   #{mounts => wasi_preview2:command_mounts(Opts)}),
                 wasi_p3_sockets:sockets(Opts),
                 wasi_p3_http:http(Opts)]).

-doc """
Run a command component, 0.2 or 0.3, as `wasi_preview2:run_command/3` does.
A 0.3 `wasi:cli/run` export is async, and its task is run to its end.
""".
-spec run_command(binary(), binary(), map()) ->
          {ok, #{stdout := binary(), stderr := binary(), exit_code := integer()}} |
          {error, term()}.
run_command(Bin, Stdin, Extra) ->
    wasi_preview2:run_command_with(Bin, Stdin, Extra, fun command/1).

-doc """
Serve one request through a `wasi:http` handler, 0.2 or 0.3, as
`wasi_preview2:run_serve/3` does. A 0.3 handler is async: its response is
taken once it has one, and its body read while the task writes it; what the
guest does after that runs too, before the instance is destroyed.
""".
-spec run_serve(binary(), map(), map()) ->
          {ok, non_neg_integer(), [{binary(), binary()}], binary()} | {error, term()}.
run_serve(Bin, Request, Extra) ->
    wasi_preview2:run_serve_with(Bin, Request, Extra, fun command/1, fun serve/2).

serve(Instance, Request) ->
    case [E || E <- wasm_component:exports(Instance),
               binary:match(E, ~"wasi:http/handler@0.3") =/= nomatch] of
        [Handler | _] -> serve_p3(Instance, <<Handler/binary, "#handle">>, Request);
        [] -> wasi_preview2:serve(Instance, Request)
    end.

serve_p3(Instance, Export, Request) ->
    Req = wasi_p3_http:incoming_request(Request),
    Sig = {[handle], {result, handle, wasi_http:error_code()}},
    case wasm_component:start_async(Instance, Export, Sig, [Req]) of
        {ok, {ok, Resp}} ->
            Result = wasi_p3_http:take_response(Resp),
            _ = wasm_component:pump(Instance, 5000),
            Result;
        {ok, {error, E}} -> {error, E};
        {error, _} = E -> E
    end.

-doc "`wasi:cli` at 0.3: stdio through streams, the environment, exit, terminals.".
-spec cli(map()) -> host().
cli(Opts) ->
    Stdout = maps:get(stdout, Opts, fun(_) -> ok end),
    Stderr = maps:get(stderr, Opts, fun(_) -> ok end),
    Stdin = maps:get(stdin, Opts, <<>>),
    Cwd = case maps:find(initial_cwd, Opts) of
              {ok, C} -> {some, C};
              error -> none
          end,
    Env = maps:get(env, Opts, []),
    Args = maps:get(args, Opts, []),
    E = ~"wasi:cli/environment@0.3",
    Exit = ~"wasi:cli/exit@0.3",
    maps:merge(
      #{{~"wasi:cli/stdout@0.3", ~"write-via-stream"} => write_via_stream(Stdout),
        {~"wasi:cli/stderr@0.3", ~"write-via-stream"} => write_via_stream(Stderr),
        {~"wasi:cli/stdin@0.3", ~"read-via-stream"} => read_via_stream(Stdin),
        {E, ~"get-environment"} =>
            wasm_component:import_fun({[], {list, {tuple, [string, string]}}},
                                      fun([]) -> Env end),
        {E, ~"get-arguments"} =>
            wasm_component:import_fun({[], {list, string}}, fun([]) -> Args end),
        {E, ~"get-initial-cwd"} =>
            wasm_component:import_fun({[], {option, string}}, fun([]) -> Cwd end)},
      maps:merge(rekey(Exit, wasi_preview2:cli_exit()), terminals())).

%% The guest's stream is the host's from now on: every write reaches the sink
%% as it is made. The future answers at once: the sink takes each write before
%% the guest's `stream.write' returns, so there is nothing left to wait for.
write_via_stream(Sink) ->
    wasm_component:import_fun(
      {[{stream, u8}], {future, ?STDIO_RESULT}},
      fun([H]) ->
              ok = wasm_async:host_sink(H, fun(eof) -> ok; (B) -> Sink(B) end),
              resolved({ok, undefined})
      end).

%% A stream a producer fills with the whole input, then ends; and a future that
%% reports how reading went.
read_via_stream(Stdin) ->
    wasm_component:import_fun(
      {[], {tuple, [{stream, u8}, {future, ?STDIO_RESULT}]}},
      fun([]) ->
              R = wasm_async:new_stream_channel(u8),
              Status = case Stdin of
                           eisdir -> {error, ~"io"};
                           _ -> {ok, undefined}
                       end,
              Data = case Stdin of eisdir -> <<>>; Bin -> Bin end,
              ok = wasm_async:register_producer(
                     R, fun(#{owner := O, task_ref := Ref, handle := H}) ->
                                O ! {async_ready, Ref, H, {data, Data}},
                                O ! {async_ready, Ref, H, close}
                        end),
              {R, resolved(Status)}
      end).

resolved(Value) ->
    {R, W} = wasm_async:host_future(?STDIO_RESULT),
    ok = wasm_async:host_future_resolve(W, Value),
    R.

terminals() ->
    None = fun(Iface, Field) ->
                   {{<<"wasi:cli/", Iface/binary, "@0.3">>, Field},
                    wasm_component:import_fun({[], {option, handle}},
                                              fun([]) -> none end)}
           end,
    maps:from_list([None(~"terminal-stdin", ~"get-terminal-stdin"),
                    None(~"terminal-stdout", ~"get-terminal-stdout"),
                    None(~"terminal-stderr", ~"get-terminal-stderr")]).

-doc """
`wasi:clocks` at 0.3: the monotonic clock with async `wait-for` and
`wait-until`, the system clock, and a timezone that reports UTC.
""".
-spec clocks() -> host().
clocks() ->
    M = ~"wasi:clocks/monotonic-clock@0.3",
    S = ~"wasi:clocks/system-clock@0.3",
    Tz = ~"wasi:clocks/timezone@0.3",
    Instant = {record, [{~"seconds", s64}, {~"nanoseconds", u32}]},
    #{{M, ~"now"} =>
          wasm_component:import_fun({[], u64},
                                    fun([]) -> wasi_preview2:monotonic_now() end),
      {M, ~"get-resolution"} => wasm_component:import_fun({[], u64}, fun([]) -> 1 end),
      %% The import's result is how many nanoseconds to wait; the producer
      %% sleeps that long, and the guest's task waits meanwhile.
      {M, ~"wait-for"} =>
          {async_import, {[u64], none}, fun([D]) -> wait(D) end, {producer, fun timer/1}},
      {M, ~"wait-until"} =>
          {async_import, {[u64], none},
           fun([When]) -> wait(When - wasi_preview2:monotonic_now()) end,
           {producer, fun timer/1}},
      {S, ~"now"} =>
          wasm_component:import_fun(
            {[], Instant},
            fun([]) ->
                    Ns = erlang:system_time(nanosecond),
                    #{~"seconds" => Ns div 1000000000,
                      ~"nanoseconds" => Ns rem 1000000000}
            end),
      {S, ~"get-resolution"} => wasm_component:import_fun({[], u64}, fun([]) -> 1000 end),
      {Tz, ~"iana-id"} =>
          wasm_component:import_fun({[], {option, string}}, fun([]) -> {some, ~"UTC"} end),
      {Tz, ~"utc-offset"} =>
          wasm_component:import_fun({[Instant], {option, s64}}, fun([_]) -> {some, 0} end),
      {Tz, ~"to-debug-string"} =>
          wasm_component:import_fun({[], string}, fun([]) -> ~"UTC" end)}.

%% A wait that is already over completes at once: the guest sees it ready
%% without suspending.
wait(Ns) when Ns =< 0 -> {returned, undefined};
wait(Ns) -> Ns.

timer(#{owner := O, task_ref := Ref, handle := H, value := Ns}) ->
    sleep((Ns + 999999) div 1000000),
    O ! {async_ready, Ref, H, subtask_complete}.

%% `after' takes at most 2^32 - 1 ms, about 49 days; a guest may ask for more.
sleep(Ms) when Ms > 4294967295 ->
    receive after 4294967295 -> ok end,
    sleep(Ms - 4294967295);
sleep(Ms) ->
    receive after Ms -> ok end.

-doc "`wasi:random` at 0.3: the same functions as 0.2.".
-spec random() -> host().
random() ->
    P2 = wasi_preview2:random(),
    Seed = maps:get({~"wasi:random/insecure-seed", ~"insecure-seed"}, P2),
    maps:merge(
      maps:from_list([{{<<I/binary, "@0.3">>, F}, Fun}
                      || {{I, F}, Fun} <- maps:to_list(P2),
                         I =/= ~"wasi:random/insecure-seed"]),
      #{{~"wasi:random/insecure-seed@0.3", ~"get-insecure-seed"} => Seed}).

%% A 0.2 interface whose functions are unchanged in 0.3, under its 0.3 key.
rekey(Iface, P2) ->
    maps:from_list([{{Iface, F}, Fun} || {{_I, F}, Fun} <- maps:to_list(P2)]).
