-module(wasi).
-moduledoc """
Run a WASI command module and get its exit status and output back.

Use this when your guest is a program with a `main` rather than a library of
exported functions. A `_start` module reports its exit status by trapping and
writes its output to whatever sink your capability map names; collecting both is
mechanical and easy to get subtly wrong, so it lives here rather than in every
caller.

```erlang
{ok, Mod} = wasm:load_file("hello.wasm"),
{ok, 0, Stdout, _Stderr} =
    wasi:run(Mod, #{args => [~"hello"],
                    dirs => [{~"/data", "/srv/app/data", read}]}).
```

`wasi_preview1` documents the capabilities. The short version: leave a key out
and the module does not have that capability, and no `dirs` means no filesystem
at all rather than one rooted at your working directory.
""".

-export([run/1, run/2, imports/1]).

-doc "Build the WASI import map for a capability configuration.".
-spec imports(map()) -> map().
imports(Config) -> wasi_preview1:imports(Config).

-spec run(wasm:module_()) -> {ok, integer(), binary(), binary()} | {error, term()}.
run(Module) -> run(Module, #{}).

-doc """
Instantiate a module, run `_start`, and collect its exit status and output.

You get the exit status back from the trap `proc_exit` raises, because trapping
is the only way to unwind a WebAssembly stack. A module that returns from
`_start` without calling `proc_exit` exits 0, which is what the WASI command
model specifies.

Output is captured by pointing stdout and stderr at this process and draining
the mailbox, so any `stdout` or `stderr` you put in `Config` is overridden.
""".
-spec run(wasm:module_(), map()) ->
          {ok, integer(), binary(), binary()} | {error, term()}.
run(Module, Config0) ->
    %% Tagging each sink separately is what lets the two streams be told apart
    %% in the mailbox; a shared pid would interleave them irrecoverably.
    Self = self(),
    OutTag = make_ref(),
    ErrTag = make_ref(),
    Config = Config0#{stdout => fun(D) -> Self ! {OutTag, D}, ok end,
                      stderr => fun(D) -> Self ! {ErrTag, D}, ok end},
    case wasm:instantiate(Module, wasi_preview1:imports(Config)) of
        {error, _} = Error ->
            Error;
        {ok, Inst} ->
            Result = wasm:call(Inst, ~"_start", []),
            Out = drain(OutTag),
            Err = drain(ErrTag),
            ok = wasm:destroy(Inst),
            case Result of
                {ok, _} ->
                    {ok, 0, Out, Err};
                {error, E} ->
                    case wasi_preview1:exit_code(E) of
                        {ok, Code} -> {ok, Code, Out, Err};
                        %% A genuine trap, not an exit: report it as a failure
                        %% rather than inventing a status for it.
                        error -> {error, E}
                    end
            end
    end.

%% Everything has already been written by the time `_start` returns, so this
%% only needs to empty what is queued, not wait for more.
drain(Tag) -> iolist_to_binary(drain(Tag, [])).

drain(Tag, Acc) ->
    receive {Tag, Data} -> drain(Tag, [Data | Acc])
    after 0 -> lists:reverse(Acc)
    end.
