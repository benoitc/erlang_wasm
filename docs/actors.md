# Actors

An actor is a WebAssembly component that handles typed messages, one at a
time, in an OTP process of its own. Use one when a guest has to keep state
between messages and talk to other actors or to Erlang processes, and you
want a supervisor, not your own code, to decide what happens when it fails.
If each request should start from a clean instance, use a
[worker](worker.md) instead.

`wasm_actor` is the API: `start_link/2` and `send/2`. The module doc is the
reference.

## The contract a guest implements

The guest imports `post` and exports `handle`. The message type is yours;
`send-error` is the runtime's and keeps its two cases in this order:

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

The runtime calls `handle` once per message, never two at once, so the guest
needs no lock around its state. Inside `handle`, `post` sends a message to
the destination you wired at start.

In C, you generate the bindings with `wit-bindgen c` and write the handler.
This one keeps a total and posts it after each `add`:

<!-- check: skip "needs the header wit-bindgen generates from the world" -->
```c
#include "counter_actor.h"

static uint32_t total;

void exports_counter_actor_handle(counter_actor_message_t *msg) {
    if (msg->tag != DEMO_ACTORS_PROTOCOL_MESSAGE_ADD)
        return;
    total += msg->val.add;
    counter_actor_message_t out = {
        .tag = DEMO_ACTORS_PROTOCOL_MESSAGE_ADDED,
        .val.added = total,
    };
    counter_actor_send_error_t err;
    (void) counter_actor_post(&out, &err);
}
```

The `wasm_demo` project builds this guest and runs it: see its `actor/`
directory and `wasm_demo:actor_demo/0`.

## Start an actor under your supervisor

You pass the same message type to the host, as a `wasm_canon` descriptor,
and say where the guest's posts go. `to` takes an actor's pid or registered
name, `self`, or a `fun(Msg)` that answers `ok` or `{error, full | closed}`.
A fun is how a plain Erlang process receives what an actor posts:

```erlang
Message = {variant, [{~"add", u32}, {~"added", u32}]},
Observer = self(),
To = fun(Msg) -> Observer ! {counter_a, Msg}, ok end,
{ok, Prepared} = wasm_component:prepare(Bin),
{ok, A} = wasm_actor:start_link(Prepared, #{message => Message,
                                            register => counter_a,
                                            to => To}).
```

Prepare the component once, so every restart instantiates it without
decoding it again, and hold it with `wasm_component:hold/1` from your
supervisor's `init/1`. An actor that is the last one running a component is
its modules' only holder; without the hold, each restart loads them again and
counts against `max_module_loads_per_second`. Keep it out of the child spec: a supervisor prints a
child's start arguments in each crash report, and a prepared component is
large. Store it where your start function finds it, for example in
`persistent_term` when your supervisor starts, and name that function in the
child spec:

```erlang
start_counter(Name, Observer) ->
    wasm_actor:start_link(persistent_term:get({my_app, counter}),
                          #{message => {variant, [{~"add", u32},
                                                  {~"added", u32}]},
                            register => Name,
                            to => fun(Msg) -> Observer ! {Name, Msg}, ok end}).
```

<!-- check: modules my_app_sup -->
```erlang
#{id => counter_a,
  start => {my_app_sup, start_counter, [counter_a, self()]}}.
```

The name is registered once the actor's queue exists, so a sender that finds
the name can send to it. That holds for a restarted actor too.

The `wasm` application must be running: list it in your application's
`applications`.

## Send a message

```erlang
case wasm_actor:send(counter_a, {~"add", 2}) of
    ok -> queued;
    {error, full} -> try_later;
    {error, closed} -> gone
end.
```

`ok` means the message is in the actor's queue. Two things hold once it is:

- messages one sender admits to one actor are handled in the order sent;
- the queue never holds more than `capacity` messages (1024 unless you set
  it), however many processes send at once.

`ok` does not mean the message will be handled: an actor that stops drops its
queue. If you need to know, have the guest post a reply.

`send/2` never waits for the actor to run. A handler can post to another
actor, or to itself, and return.

## Handle `full` and `closed`

- `{error, full}`: the actor is alive and behind. Nothing was queued. Retry
  later, drop the message, or slow the sender down. A guest that gets `full`
  from `post` should not retry inside the same `handle`: when the destination
  is itself, the queue cannot drain until `handle` returns.
- `{error, closed}`: there is no actor there. It stopped, it was never
  started, or the name is not registered. A supervised actor that is
  restarting comes back with a new pid under the same name, so send to the
  name and retry.

A guest gets the same two answers from `post`.

A message that does not fit the actor's type raises `badarg` in `send/2`: the
mistake is the caller's, and nothing is queued.

## When the guest traps

A trap in `handle` stops the actor with `{handle_failed, Error}`. Its
instance is destroyed and its memory goes back to the node before the
process exits. The supervisor then starts a new actor on a new instance, so
the guest's state starts from the beginning:

```erlang
Mon = monitor(process, whereis(counter_a)),
receive {'DOWN', Mon, process, _, {handle_failed, Error}} -> Error end.
```

## Notes

- An actor killed outright (`exit(Pid, kill)`) does not run its cleanup; the
  runtime notices a moment later. Until then a send to it may answer `ok`,
  and the message is lost with the actor, as any message to a process that is
  exiting is.
- The message type must be a plain value. Resources, futures and streams
  belong to one instance and cannot travel to another, so `start_link/2`
  refuses a type that holds them.
- `imports` adds host functions for the guest beside `post`, and `limits`
  bounds its instance as for `wasm_component:instantiate/3`.
