-module(wasm_actor).
-moduledoc """
A WebAssembly component that handles typed messages, one at a time, as an OTP
process. `docs/actors.md` is the guide; this is the reference.

An actor owns one component instance for its whole life, so the guest keeps
its state from one message to the next. It takes messages from Erlang through
`send/2` and from its own guest, which posts them to a destination you wire
when you start it. It is a `gen_server`, so you put it under your own
supervisor like any other child.

The guest implements this world. The message type is yours: name it what you
like, give it the cases your application needs, and pass the same type to
`start_link/2` as `message`. The `send-error` enum is the runtime's and must
keep its two cases in this order.

```text
package demo:actors@0.1.0;

interface protocol {
    variant message { add(u32), added(u32) }
    enum send-error { full, closed }
}

world counter-actor {
    use protocol.{message, send-error};
    import post: func(msg: message) -> result<_, send-error>;
    export handle: func(msg: message);
}
```

## What a successful send means

`send/2` answers `ok` when the message is in the destination's queue. It does
not wait for the actor to run, so a handler can post to any actor, itself
included, and return. Admission promises two things:

- **Order.** Two messages one sender admits to one actor are handled in the
  order they were sent. Messages from different senders interleave.
- **A bound.** An actor's queue never holds more than its `capacity`, however
  many processes send at once. The message being handled does not count.

It does not promise that the message is handled. An actor that stops, by a
trap, a supervisor or a kill, drops what is still in its queue. If you need to
know a message was handled, have the guest post a reply.

## When a send is refused

- `{error, full}`: the queue is at its capacity. Nothing was queued. The actor
  is alive and working, so you may retry later, drop the message, or slow
  down the sender. Retrying in a tight loop from inside a handler can never
  succeed when the destination is the actor itself.
- `{error, closed}`: no actor is there: it stopped, it was never started, or
  the name is not registered. A supervised actor that is restarting has a new
  pid, so send to its registered name, or look the new pid up, and retry.

A guest sees the same two answers, as the `send-error` result of `post`.

A message that does not fit the destination's type is not refused: `send/2`
raises `badarg`, because the mistake is the caller's. A guest post can only
make that mistake if you wired two actors of different message types
together, and then the posting actor stops with the reason.

## When the guest fails

A trap in `handle`, or any error from the call, stops the actor with
`{handle_failed, Error}` as its exit reason, `Error` being the error map the
runtime gives for the call. The instance is destroyed before the process
exits, so its memory goes back to the node. A supervisor then starts a new
actor with a new instance, whose state starts from the beginning.

## What it needs

The `wasm` application must be running: senders find an actor through a
table it owns.
""".

-behaviour(gen_server).

-export([start_link/2, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([dest/0, to/0, opts/0]).

-define(TAB, wasm_actors).
-define(TAG, '$wasm_actor').
-define(DEFAULT_CAPACITY, 1024).
-define(SEND_ERROR, {enum, [~"full", ~"closed"]}).
-define(POST, {~"$root", ~"post"}).
-define(HANDLE, ~"handle").

-type dest() :: pid() | atom().
-type to() :: dest() | self
            | fun((term()) -> ok | {error, full | closed}).
-type opts() :: #{message := wasm_canon:desc(),
                  to => to(),
                  capacity => pos_integer(),
                  register => atom(),
                  imports => #{{binary(), binary()} => function()},
                  limits => map()}.

-record(state, {instance, message, counter}).

%%% ------------------------------------------------------------------ api ---

-doc """
Start an actor over a component, linked to the caller.

`Component` is the component's bytes, or what `wasm_component:prepare/1`
made of them: prepare once and every restart skips decoding. Keep it out
of a child spec, which a supervisor prints in every crash report, and hold it
(`wasm_component:hold/1`) from a process that outlives the actor, so a
restart finds its modules loaded.

`Opts`:

- `message` (required): the message type, as a `wasm_canon` descriptor. It
  must be a plain value: no resources, futures or streams, which belong to one
  instance and cannot travel to another.
- `to`: where the guest's `post` goes. An actor's pid or registered name, read
  again on every post so a restarted actor is found by its name; `self`; or a
  `fun(Msg)` that answers `ok` or `{error, full | closed}`, which is how an
  Erlang process that is not an actor receives. Left out, every post answers
  `closed`.
- `capacity`: how many messages the queue holds, 1024 when left out.
- `register`: a local name to register the actor under. It is registered
  once the queue exists, so a sender that finds the name can send to it; a
  name already taken is `{error, {already_started, Pid}}`.
- `imports`: more host functions for the guest, keyed as for
  `wasm_component:instantiate/2`. `post` is the actor's own.
- `limits`: instance limits, as `wasm_component:instantiate/3` takes them.

The instance is made before this returns, so a component that does not
instantiate, or has no `handle` export, is an `{error, Reason}` here and not a
crash later.
""".
-spec start_link(binary() | wasm_component:prepared(), opts()) ->
          {ok, pid()} | {error, term()}.
start_link(Component, Opts) ->
    gen_server:start_link(?MODULE, {Component, Opts}, []).

-doc """
Queue `Msg` for the actor at `Dest`, a pid or a registered name.

Answers `ok` once the message is in the queue, `{error, full}` when the queue
is at its capacity and `{error, closed}` when no actor is there. It never
waits for the actor. Raises `badarg` when `Msg` does not fit the actor's
message type.
""".
-spec send(dest(), term()) -> ok | {error, full | closed}.
send(Dest, Msg) ->
    case lookup(Dest) of
        {ok, Pid, Counter, Capacity, Type} ->
            fits(Type, Msg) orelse error(badarg, [Dest, Msg]),
            admit(Pid, Counter, Capacity, Msg);
        closed ->
            {error, closed}
    end.

%%% ------------------------------------------------------------ callbacks ---

init({Component, Opts}) ->
    %% Exits are trapped so `terminate/2' runs on a supervisor's shutdown and
    %% the instance is destroyed then, not whenever the process is collected.
    process_flag(trap_exit, true),
    proc_lib:set_label({?MODULE, maps:get(register, Opts, undefined)}),
    case setup(Component, Opts) of
        {ok, State} -> {ok, State};
        {error, Reason} -> {error, Reason}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({?TAG, Msg}, #state{instance = Inst, message = Type,
                                counter = Counter} = State) ->
    %% Out of the queue: its slot is free before the guest runs, so a post
    %% from this handler to this actor finds room for one more.
    _ = atomics:sub(Counter, 1, 1),
    case wasm_component:call(Inst, ?HANDLE, {[Type], none}, [Msg]) of
        {ok, _} -> {noreply, State};
        {error, Error} -> {stop, {handle_failed, Error}, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% The row goes first, so a send from now on answers `closed', then the
%% instance and its memory.
terminate(_Reason, #state{instance = Inst}) ->
    true = ets:delete(?TAB, self()),
    wasm_component:destroy(Inst).

%%% -------------------------------------------------------------- helpers ---

setup(Component, Opts) ->
    Type = maps:get(message, Opts, undefined),
    Capacity = maps:get(capacity, Opts, ?DEFAULT_CAPACITY),
    To = maps:get(to, Opts, undefined),
    if
        Type =:= undefined -> {error, no_message_type};
        not is_integer(Capacity) orelse Capacity < 1 ->
            {error, {bad_capacity, Capacity}};
        true ->
            case plain(Type) of
                true -> start(Component, Opts, Type, Capacity, To);
                false -> {error, {bad_message_type, Type}}
            end
    end.

start(Component, Opts, Type, Capacity, To) ->
    Name = maps:get(register, Opts, undefined),
    case ets:whereis(?TAB) of
        undefined -> {error, wasm_not_started};
        _ when not is_atom(Name) -> {error, {bad_name, Name}};
        _ -> free_name(Name, Component, Opts, Type, Capacity, To)
    end.

%% A name already taken is refused before any instance is built for it.
free_name(Name, Component, Opts, Type, Capacity, To) ->
    case Name =/= undefined andalso whereis(Name) of
        Pid when is_pid(Pid) ->
            {error, {already_started, Pid}};
        _ ->
            Imports = (maps:get(imports, Opts, #{}))#{?POST => post(To, Type)},
            Limits = maps:get(limits, Opts, #{}),
            case wasm_component:instantiate(Component, Imports, Limits) of
                {ok, Inst} -> ready(Inst, Type, Capacity, Name);
                {error, _} = E -> E
            end
    end.

ready(Inst, Type, Capacity, Name) ->
    case lists:member(?HANDLE, wasm_component:exports(Inst)) of
        true ->
            Counter = atomics:new(1, [{signed, true}]),
            true = ets:insert(?TAB, {self(), Counter, Capacity, Type}),
            ok = wasm_actor_registry:watch(self()),
            State = #state{instance = Inst, message = Type, counter = Counter},
            case named(Name) of
                ok -> {ok, State};
                {error, _} = E -> terminate(normal, State), E
            end;
        false ->
            ok = wasm_component:destroy(Inst),
            {error, no_handle_export}
    end.

%% The name is registered last, not by `gen_server' before `init/1': a
%% sender that finds the name then finds the queue too, so a restarted actor
%% is never `closed' to someone who just looked it up.
named(undefined) ->
    ok;
named(Name) ->
    try register(Name, self()) of
        true -> ok
    catch
        error:badarg -> {error, {already_started, whereis(Name)}}
    end.

%% The guest's `post', which runs in this process while `handle' runs.
post(To, Type) ->
    wasm_component:import_fun(
      {[Type], {result, none, ?SEND_ERROR}},
      fun([Msg]) ->
          case deliver(To, Msg) of
              ok -> {ok, undefined};
              {error, full} -> {error, ~"full"};
              {error, closed} -> {error, ~"closed"}
          end
      end).

deliver(undefined, _Msg) -> {error, closed};
deliver(self, Msg) -> send(self(), Msg);
deliver(Fun, Msg) when is_function(Fun, 1) -> Fun(Msg);
deliver(Dest, Msg) -> send(Dest, Msg).

lookup(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> closed;
        Pid -> lookup(Pid)
    end;
lookup(Pid) when is_pid(Pid) ->
    %% No table means no `wasm' application, so no actor anywhere.
    try ets:lookup(?TAB, Pid) of
        [{Pid, Counter, Capacity, Type}] -> {ok, Pid, Counter, Capacity, Type};
        [] -> closed
    catch
        error:badarg -> closed
    end;
lookup(_Other) ->
    closed.

%% The counter goes up before the check, so senders racing for the last slot
%% cannot both take it: each one past the capacity gives its increment back.
admit(Pid, Counter, Capacity, Msg) ->
    case atomics:add_get(Counter, 1, 1) of
        N when N > Capacity ->
            _ = atomics:sub(Counter, 1, 1),
            {error, full};
        _ ->
            Pid ! {?TAG, Msg},
            ok
    end.

%% A message type that can cross from one instance to another: values only.
plain(T) when T =:= u8; T =:= u16; T =:= u32; T =:= u64; T =:= s8;
              T =:= s16; T =:= s32; T =:= s64; T =:= f32; T =:= f64;
              T =:= bool; T =:= char; T =:= string -> true;
plain({list, T}) -> plain(T);
plain({option, T}) -> plain(T);
plain({tuple, Ts}) when is_list(Ts) -> lists:all(fun plain/1, Ts);
plain({record, Fs}) when is_list(Fs) ->
    lists:all(fun({N, T}) -> is_binary(N) andalso plain(T);
                 (_) -> false
              end, Fs);
plain({variant, Cs}) when is_list(Cs) ->
    lists:all(fun({N, none}) -> is_binary(N);
                 ({N, T}) -> is_binary(N) andalso plain(T);
                 (_) -> false
              end, Cs);
plain({result, Ok, Err}) -> payload(Ok) andalso payload(Err);
plain({enum, Ns}) when is_list(Ns) -> lists:all(fun is_binary/1, Ns);
plain({flags, Ns}) when is_list(Ns) -> lists:all(fun is_binary/1, Ns);
plain(_) -> false.

payload(none) -> true;
payload(T) -> plain(T).

%% Whether `V' is a value of type `T', in the shapes `wasm_canon' lowers.
fits(u8, V) -> int_in(V, 0, 16#FF);
fits(u16, V) -> int_in(V, 0, 16#FFFF);
fits(u32, V) -> int_in(V, 0, 16#FFFFFFFF);
fits(u64, V) -> int_in(V, 0, 16#FFFFFFFFFFFFFFFF);
fits(s8, V) -> int_in(V, -16#80, 16#7F);
fits(s16, V) -> int_in(V, -16#8000, 16#7FFF);
fits(s32, V) -> int_in(V, -16#80000000, 16#7FFFFFFF);
fits(s64, V) -> int_in(V, -16#8000000000000000, 16#7FFFFFFFFFFFFFFF);
fits(F, V) when F =:= f32; F =:= f64 -> is_float(V);
fits(bool, V) -> is_boolean(V);
fits(char, V) ->
    int_in(V, 0, 16#10FFFF) andalso not int_in(V, 16#D800, 16#DFFF);
fits(string, V) ->
    is_binary(V) andalso unicode:characters_to_binary(V) =:= V;
fits({list, u8}, V) -> is_binary(V);
fits({list, T}, V) -> is_list(V) andalso lists:all(fun(E) -> fits(T, E) end, V);
fits({option, _T}, none) -> true;
fits({option, T}, {some, V}) -> fits(T, V);
fits({tuple, Ts}, V) ->
    is_tuple(V) andalso tuple_size(V) =:= length(Ts)
        andalso lists:all(fun({T, E}) -> fits(T, E) end,
                          lists:zip(Ts, tuple_to_list(V)));
fits({record, Fs}, V) ->
    is_map(V) andalso map_size(V) =:= length(Fs)
        andalso lists:all(fun({N, T}) -> is_map_key(N, V)
                                             andalso fits(T, map_get(N, V))
                          end, Fs);
fits({variant, Cs}, {N, P}) ->
    case lists:keyfind(N, 1, Cs) of
        {N, T} -> fits_payload(T, P);
        false -> false
    end;
fits({result, Ok, _Err}, {ok, P}) -> fits_payload(Ok, P);
fits({result, _Ok, Err}, {error, P}) -> fits_payload(Err, P);
fits({enum, Ns}, V) -> lists:member(V, Ns);
fits({flags, Ns}, V) ->
    is_list(V) andalso lists:all(fun(N) -> lists:member(N, Ns) end, V);
fits(_T, _V) -> false.

fits_payload(none, P) -> P =:= undefined;
fits_payload(T, P) -> fits(T, P).

int_in(V, Lo, Hi) -> is_integer(V) andalso V >= Lo andalso V =< Hi.
