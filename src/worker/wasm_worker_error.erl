-module(wasm_worker_error).
-moduledoc """
The worker's own error type, and the closed set of kinds it can carry.

Every entry point in `wasm_script_worker` answers with one of these or with a
result. Nothing raises, which is the runtime's rule applied to the layer above
it: a dead worker, an exhausted limit and a guest that trapped are all values.

## Why this is not a `wasm_error`

`t:wasm_error:class/0` is `malformed | invalid | link | trap | exhaustion`, and
none of those describes a request that ran out of wall clock or a caller that
cancelled. Inventing a sixth class would put worker vocabulary in the runtime's
namespace, where a future runtime change would have to keep it working. So the
worker has its own type and the runtime's errors travel inside it untouched:

```erlang
#{class => runtime, kind => runtime_failure, msg => ~"trap",
  ctx => #{error => WasmError}}
```

The runtime's own class and kind are still there, in `ctx.error`, where they
can grow without anything here changing.

## The kind is always an atom this module names

`t:kind/0` below is the whole set. That matters because of the other half of the
rule: **nothing a guest supplies becomes an atom.** The atom table is node-wide
and never reclaimed, so a language's own vocabulary travels as a **binary** in
`ctx`, never as a kind:

```erlang
#{class => adapter, kind => adapter_failure, msg => ~"main is not defined",
  ctx => #{code => ~"no_entry_point"}}
```

`adapter_failure` is the kind; `~"no_entry_point"` is the profile's code. A
profile can add codes for ever and this set does not move.

## Building one

```erlang
wasm_worker_error:worker(timeout, ~"deadline reached", #{after_ms => 5000}),
wasm_worker_error:adapter(exit, ~"non-zero exit", #{code => 2}),
wasm_worker_error:runtime(WasmError).
```
""".

-export([worker/3, adapter/3, runtime/1, runtime/2]).
-export([kinds/0, is_error/1, class_of/1, kind_of/1]).

-doc """
Which layer decided the request had failed.

`worker` is the kernel's own judgement, `adapter` is the adapter's, and
`runtime` means the runtime returned an error and nobody reinterpreted it.
""".
-type class() :: worker | adapter | runtime.

-doc """
Every kind the worker can produce. Closed, and checked by `is_error/1`.

A guest or an adapter that needs a vocabulary of its own puts a binary in
`ctx`, because this set must not grow with the number of languages.
""".
-type kind() :: timeout
              | cancelled
              | output_limit
              | result_limit
              | crashed
              | insufficient_limit
              | bad_stage_path
              | busy
              | no_reaper
              | cleanup_saturated
              | still_running
              | already_awaited
              | unknown_ref
              | no_worker
              | worker_died
              | exit
              | adapter_failure
              | runtime_failure.

-doc "What every worker entry point answers with when it does not answer `ok`.".
-type worker_error() :: #{class := class(),
                          kind := kind(),
                          msg := binary(),
                          ctx := map()}.

-export_type([class/0, kind/0, worker_error/0]).

%%% ------------------------------------------------------------ building ---

-doc "An error the kernel itself decided on.".
-spec worker(kind(), binary(), map()) -> worker_error().
worker(Kind, Msg, Ctx) -> #{class => worker, kind => Kind, msg => Msg, ctx => Ctx}.

-doc """
An error the adapter diagnosed.

Only two kinds are available, `exit` and `adapter_failure`, and that is
deliberate: an adapter with more to say says it as a binary code in `ctx`.
""".
-spec adapter(exit | adapter_failure, binary(), map()) -> worker_error().
adapter(Kind, Msg, Ctx) when Kind =:= exit; Kind =:= adapter_failure ->
    #{class => adapter, kind => Kind, msg => Msg, ctx => Ctx}.

-doc """
Wrap a runtime error without reinterpreting it.

The kind is always `runtime_failure`. The runtime's own class and kind stay in
`ctx.error`, so a trap, an exhausted fuel budget and a memory refusal are told
apart by reading that rather than by this set growing three more atoms.
""".
-spec runtime(wasm_error:error()) -> worker_error().
runtime(Err) -> runtime(Err, #{}).

-spec runtime(wasm_error:error(), map()) -> worker_error().
runtime(Err, Ctx) ->
    #{class => runtime, kind => runtime_failure,
      msg => runtime_msg(Err), ctx => Ctx#{error => Err}}.

%% The runtime's message if it has one, and a constant if it does not. Never
%% anything derived from guest bytes, which is what `msg` being a binary is
%% for: it is shown, not matched on.
runtime_msg(#{msg := Msg}) when is_binary(Msg) -> Msg;
runtime_msg(_) -> ~"runtime error".

%%% ------------------------------------------------------------ checking ---

-doc """
Every kind this module can produce.

Exported so the conformance kit can assert that an adapter did not invent one,
which is the check that keeps the set closed.
""".
-spec kinds() -> [kind()].
kinds() ->
    [timeout, cancelled, output_limit, result_limit, crashed, insufficient_limit,
     bad_stage_path, busy, no_reaper, cleanup_saturated, still_running,
     already_awaited, unknown_ref, no_worker, worker_died, exit, adapter_failure,
     runtime_failure].

-doc """
Whether a term is a well-formed worker error.

All four keys, a known class, a kind from `kinds/0`, a binary message and a map
context. The kit asserts this on every error every adapter produces, which is
what makes the error model a contract rather than a convention.
""".
-spec is_error(term()) -> boolean().
is_error(#{class := Class, kind := Kind, msg := Msg, ctx := Ctx})
  when is_binary(Msg), is_map(Ctx) ->
    lists:member(Class, [worker, adapter, runtime]) andalso
        lists:member(Kind, kinds()) andalso
        class_allows(Class, Kind);
is_error(_) ->
    false.

%% The class and the kind are not independent. An `adapter' error carrying
%% `timeout' would say the adapter decided something only the kernel can
%% decide, and a `runtime' error carrying anything but `runtime_failure' would
%% reopen the outer set this module exists to close.
class_allows(adapter, Kind) -> Kind =:= exit orelse Kind =:= adapter_failure;
class_allows(runtime, Kind) -> Kind =:= runtime_failure;
class_allows(worker, Kind) ->
    not lists:member(Kind, [exit, adapter_failure, runtime_failure]).

-spec class_of(worker_error()) -> class().
class_of(#{class := C}) -> C.

-spec kind_of(worker_error()) -> kind().
kind_of(#{kind := K}) -> K.
