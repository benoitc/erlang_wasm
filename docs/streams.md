# Talking to a guest while it runs

This page shows you how to keep a guest running and exchange messages with
it, instead of calling it and waiting for the result. Read it when the module
you run is a server rather than a function: a script with its own read loop, a
language runtime such as QuickJS or CPython that answers one request at a
time, or a program whose output you want while it is produced.

With a host function, the guest asks you a question and waits for your
answer. With a stream, you send data to the guest and read what it writes, and
neither side finishes.

There is no separate API for this. Two of the WASI capabilities in
[wasi.md](wasi.md) already accept a function, and that function may block
(wait without returning):

| capability | give it | what the guest sees |
| --- | --- | --- |
| `stdin` | `fun(Want) -> {ok, Bytes} \| eof` | `fd_read` blocks until your fun returns |
| `stdout`, `stderr` | a pid, or `fun(Bytes) -> ok` | every `fd_write` arrives at once |

A pid (a process identifier) receives `{wasi_output, RunnerPid, Bytes}` for
each write. A fun runs in the process that makes the call. Use a fun when you
must join partial writes into whole messages.

## Run a guest that reads and writes

The call runs in *your* process, so a guest that streams needs a process of
its own. The process that sends it data cannot be the same one that is
blocked inside it. Let a worker process own the instance, and talk to the
worker by message.

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

The whole mechanism is this fun, which blocks:

```erlang
next_request() ->
    receive
        {req, From, Data} -> put(asker, From), {ok, iolist_to_binary(Data)};
        stop -> eof
    after 60000 -> eof
    end.
```

`{ok, Bytes}` answers one read. `eof` ends the guest's read loop. Then
`_start` returns and the worker finishes.

Ask it something:

```erlang
ask(Pid, Term) ->
    Pid ! {req, self(), [json:encode(Term), $\n]},
    receive {line, Pid, Line} -> json:decode(string:chomp(Line))
    after 5000 -> error(no_reply)
    end.
```

## Frame the messages yourself

Stdin is a stream of bytes. Nothing marks where one message ends, so agree
with the guest on a format that separates messages. The usual choice is one
JSON object per line. It is what `std.in.getline()` in QuickJS and `input()`
in CPython already expect.

The same is true in the other direction. When a guest writes 4 KB, you may
receive it as several `fd_write` calls. Join them before you decide that you
have a full reply:

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

A C library that thinks it writes to a pipe collects output in blocks, not
in lines. So a guest may keep a reply until it has written enough, or until
it exits. QuickJS's `std.out.puts` with an explicit newline works correctly.
If a runtime still holds its output, call that runtime's own flush function;
you do not need to change anything on the Erlang side.

## Notes

- **Your stdin fun blocks the process that runs the call.** This is
  intended. It is also why the process that controls the guest must be a
  different process.
- **Give it an `after`.** A guest that waits on a read keeps the worker busy
  until something arrives. Without a timeout, if the caller goes away, the
  worker and its instance are never freed.
- **The mailbox controls the flow.** A slow worker simply leaves messages in
  its mailbox, and a timeout is `receive ... after`. You have nothing to
  configure.
- **To stop the guest, kill the process.** Nothing outside can interrupt
  `wasm:call/3`, so `exit(Pid, kill)` is how you stop it, and destroying the
  instance frees its pages. [worker.md](worker.md) has a table of what a
  separate process gives you.
- **One request at a time per instance.** Two callers in one instance is
  unsafe, whatever the transport: both read and write the same guest state.
  To handle more requests, start more workers.
- **A stream is not the only channel.** Anything you can write as an import is
  a host function, and a host function can send a message. Stdin and stdout
  are for programs you did not build, which import nothing but WASI.

## A working one

[`wasm_demo`](https://github.com/benoitc/wasm_demo) runs QuickJS this way: a
`priv/worker.js` that reads one line at a time, a worker process that owns the
instance, and `make test` to check that a message goes there and back.

## Read this next

[Using workers](worker.md).
