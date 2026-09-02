# Talking to a guest while it runs

This page shows you how to keep a guest running and exchange messages with it,
instead of calling it and waiting for a return. Read it when the module you are
running is a server rather than a function: a script with its own read loop, a
language runtime like QuickJS or CPython answering one request at a time, or a
program whose output you want as it is produced. A host function is the guest
asking you a question and blocking until you answer; a stream is you feeding the
guest and reading what it writes, with neither side finishing.

There is no separate API for this. Two of the WASI capabilities in
[wasi.md](wasi.md) already take a function, and a function is allowed to block:

| capability | give it | what the guest sees |
| --- | --- | --- |
| `stdin` | `fun(Want) -> {ok, Bytes} \| eof` | `fd_read` blocks until your fun returns |
| `stdout`, `stderr` | a pid, or `fun(Bytes) -> ok` | every `fd_write` arrives at once |

A pid gets `{wasi_output, RunnerPid, Bytes}` per write. A fun runs in the
process making the call, which is what you want when you have to join partial
writes into whole messages.

## Run a guest that reads and writes

The call runs in *your* process, so a streamed guest needs a process of its own:
whoever feeds it cannot be the one blocked inside it. Own the instance in a
worker and talk to it by message.

```erlang
start(Mod, Priv) ->
    Owner = self(),
    spawn_link(fun() -> loop(Mod, Priv, Owner) end).

loop(Mod, Priv, Owner) ->
    Wasi = #{args   => [~"qjs", ~"/app/worker.js"],
             dirs   => [{~"/app", Priv, read}],
             stdin  => fun(_Want) -> next_request() end,
             stdout => fun(Data) -> collect_line(Owner, Data) end,
             stderr => fun(_Data) -> ok end},
    {ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi),
                                  #{max_memory_pages => 1024}),
    _ = wasm:call(Inst, ~"_start", []),
    ok = wasm:destroy(Inst).
```

The fun that blocks is the whole mechanism:

```erlang
next_request() ->
    receive
        {req, From, Data} -> put(asker, From), {ok, iolist_to_binary(Data)};
        stop -> eof
    after 60000 -> eof
    end.
```

`{ok, Bytes}` is one read satisfied. `eof` ends the guest's read loop, which is
how `_start` returns and the worker finishes.

Ask it something:

```erlang
ask(Pid, Term) ->
    Pid ! {req, self(), [json:encode(Term), $\n]},
    receive {line, Pid, Line} -> json:decode(string:chomp(Line))
    after 5000 -> error(no_reply)
    end.
```

## Frame the messages yourself

Stdin is a byte stream. Nothing marks where one message ends, so agree on a
framing with the guest; one JSON object per line is the usual choice, and it is
what `std.in.getline()` in QuickJS and `input()` in CPython already expect.

The same applies coming back. A guest writing 4 KB may reach you as several
`fd_write` calls, so join them before you decide you have a reply:

```erlang
collect_line(Owner, Data) ->
    Buf = <<(case get(outbuf) of undefined -> <<>>; B -> B end)/binary,
            (iolist_to_binary(Data))/binary>>,
    case binary:split(Buf, ~"\n") of
        [Line, Rest] -> get(asker) ! {line, self(), Line}, put(outbuf, Rest);
        [_]          -> put(outbuf, Buf)
    end,
    ok.
```

A C library writing to what it believes is a pipe buffers in blocks rather than
lines, so a guest may hold a reply until it writes enough or exits. QuickJS's
`std.out.puts` and an explicit newline behave; if a runtime buffers anyway, its
own flush call is the answer, not a change here.

## Notes

- **Your stdin fun blocks the process running the call.** That is the point,
  and it is also why the controller has to be a different process.
- **Give it an `after`.** A guest parked on a read holds the worker until
  something arrives. Without a timeout, a caller that goes away leaks a worker
  and its instance.
- **Backpressure is the mailbox**, and a timeout is `receive ... after`. There
  is nothing to configure.
- **Stopping is killing the process.** `wasm:call/3` cannot be interrupted from
  outside, so `exit(Pid, kill)` is the stop button, and destroying the instance
  releases its pages. [worker.md](worker.md) has the table of what a process
  boundary buys.
- **One request at a time per instance.** Two callers into one instance is
  unsound whatever the transport: both read and write the same guest state.
  More throughput means more workers.
- **A stream is not the only channel.** Anything you can express as an import
  is a host function, and a host function can send a message. Stdin and stdout
  are for programs you did not build, which import nothing but WASI.

## A working one

[`wasm_demo`](https://github.com/benoitc/wasm_demo) runs QuickJS this way: a
`priv/worker.js` reading a line at a time, a worker process owning the
instance, and `make test` proving the round trip.
