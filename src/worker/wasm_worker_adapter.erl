-module(wasm_worker_adapter).
-moduledoc """
The behaviour an adapter implements: what teaches `wasm_script_worker` one
language.

The worker kernel knows about modules, imports, invocations, deadlines and
bounded channels. It does not know what WASI is, what JSON is, or that an
entry point might be called `main`. An adapter supplies all of that through
the callbacks below, and every type those callbacks name is defined here, so
this is the one module an adapter author needs to read.

```erlang
-module(my_adapter).
-behaviour(wasm_worker_adapter).
```

`wasm_adapter_conformance` is the kit that checks an adapter keeps the
contract, and `docs/worker-contract.md` is the guide to writing one.
""".

-doc "Whatever the adapter loaded once, at `start_link`. Opaque to the kernel.".
-type artifact() :: term().
-doc "One unit of tenant work. The kernel never reads inside it.".
-type request() :: term().
-doc "Whatever `prepare/3` needs `cleanup/1` to receive. Opaque.".
-type adapter_state() :: term().
-doc "What `decode/2` produced. The profile decides what is in it.".
-type result() :: term().
-doc "What a request answers with.".
-type outcome() :: {ok, result()} | {error, wasm_worker_error:worker_error()}.

-doc "Names a mount the adapter declared. Its own directory, its own mode.".
-type mount_name() :: atom().

-doc """
One host directory, preopened at `guest_path`, with one mode.

A mode cannot belong to a file: WASI grants rights to a **preopened directory
and everything opened beneath it**, so a work directory holding one read-only
and one writable staged path cannot express that. Naming mounts is how an
adapter says what it meant.
""".
-type mount() :: #{guest_path := binary(),
                   host_dir := file:filename_all(),
                   mode := read | write}.

-doc "An opaque sink. The only operation is writing to it.".
-type channel() :: {channel, atom(), ets:tid(), atomics:atomics_ref(),
                    pos_integer()}.

-doc """
Register a cleanup action, or drop one. **No transfer**, deliberately.

If an adapter could transfer and its runner then died before delivering an
`adapter_state()`, the transferred action would run only "if a state was
delivered" and none ever was, so nothing would own it. The kernel transfers
once, after the guardian holds the complete state.

Every operation can fail, and `register` says which of three things happened,
because one that returns an error having neither recorded nor performed the
action leaks exactly the resource the adapter allocated one line earlier.
""".
-type cleanup_cap() ::
        #{register := fun((action()) ->
                              {ok, token()}
                            | {error, wasm_worker_error:worker_error(),
                               released | cleanup_failed}),
          withdraw := fun((token()) ->
                              ok | {error, wasm_worker_error:worker_error()})}.

-doc """
What `prepare/3` is handed. The channels come down rather than back, because
the adapter needs them *while* it builds its imports.

`limits` are **effective, not proposed**: the adapter said what it needed in
`requirements/2`, the policy has been applied, and the deadline is built from
the result. An adapter reads them and never returns replacements.
""".
-type env() :: #{mounts := #{mount_name() => mount()},
                 channels := #{stdout := channel(), stderr := channel(),
                               result := channel()},
                 deadline := integer() | infinity,
                 limits := map(),
                 cleanup := cleanup_cap(),
                 stage := fun((mount_name(), binary(), iodata()) ->
                                  ok | {error, wasm_worker_error:worker_error()})}.

-doc """
Every extern kind the runtime resolves, not just functions.

A guest may import a memory, a table, a global or a tag, and `wasm:extern/2`
hands those out so two instances can be linked.
""".
-type import_value() :: fun((term(), [term()]) -> term())
                      | {module(), atom()}
                      | wasm:extern().

-doc """
Portable by construction.

No pid, port, reference or fun can enter the identity a snapshot is matched on,
because every one of those differs between two runs of an identical
configuration, so the key would stop matching itself.
""".
-type portable() :: binary() | number() | atom() | [portable()]
                  | tuple() | #{portable() => portable()}.

-type compatibility_key() :: portable().
-type capture() :: portable().

-doc """
How an import module participates in a snapshot. Inert until Phase 6.

Runtime-facing, so these return the runtime's error type: nothing in `src/` may
depend on this module.
""".
-type hook() :: stateless
              | #{eligible := fun((wasm:instance()) ->
                                      ok | {error, wasm_error:error()}),
                  capture := fun((wasm:instance()) ->
                                     {ok, capture()} | {error, wasm_error:error()}),
                  restore := fun((wasm:instance(), capture()) ->
                                     ok | {error, wasm_error:error()})}.

-doc """
The import set, as one type from the start so Phase 6 adds no new shape.

**Only `bindings` reaches import resolution**, because the runtime's import map
is flat and keyed by `{Module, Name}`. The other two are optional and an
adapter that ignores snapshots writes neither.
""".
-type import_set() :: #{bindings := #{{binary(), binary()} => import_value()},
                        snapshot_hooks => #{binary() => hook()},
                        compatibility_key => compatibility_key()}.

-doc "What the kernel needs in order to run the thing.".
-type execution_spec() :: #{mode := command | reactor,
                            module := wasm:module_(),
                            imports := import_set(),
                            invoke := [{call, binary(), [term()]}, ...]}.

-doc "What happened, still uninterpreted.".
-type execution_result() :: #{outcome := returned | trapped | exited,
                              values := [term()],
                              exit := undefined | integer(),
                              channels := #{stdout := binary(), stderr := binary(),
                                            result := binary()},
                              truncated := #{stdout := boolean(),
                                             stderr := boolean(),
                                             result := boolean()},
                              error := undefined | wasm_error:error()}.

-type invocation_result() :: {ok, [term()]} | {error, wasm_error:error()}.
-type stop_class() :: returned | trapped | {exited, integer()}.

-doc "What `requirements/2` answers: what this request needs and what it costs.".
-type requirements() :: #{min_timeout := pos_integer(),
                          min_memory_pages := non_neg_integer(),
                          request_bytes := non_neg_integer(),
                          staged_bytes := non_neg_integer(),
                          staged_files := non_neg_integer(),
                          mounts := #{mount_name() =>
                                          #{guest_path := binary(),
                                            mode := read | write}}}.

-doc "What the conformance kit reads to decide what to demand.".
-type capabilities() :: #{execution := command | reactor | both,
                          input_channels := [typed_args | stdin | files
                                             | custom_import],
                          result_channels := [typed_result | custom_import
                                              | framed_stream],
                          snapshots := unsupported | #{version := binary()},
                          wasi := boolean()}.

-doc "Opaque requests the kit submits. It never reads them.".
-type fixtures() :: #{base := #{echo := request(), failure := request(),
                                runaway := request(), state_change := request()},
                      by_capability := #{atom() => request()}}.

-type restore_ctx() :: #{module := wasm:module_(), version := binary()}.

-doc """
What an adapter must supply for the worker to capture an image at start.

`module` and `imports` are what the initialisation instance is built from, and
they are here rather than derived from `prepare/3` because the two are not the
same thing: an initialisation instance exists once, before any request and with
a **trusted** binding set, and is captured. `imports` also carries the
`compatibility_key` and the `snapshot_hooks` every restore is matched and
checked against, so the two sides cannot drift apart.

`init` is what to invoke before capturing, `validate` is the adapter's own
eligibility check, and `post_restore` runs inside every restore, in the runner,
on the request's remaining deadline.
""".
-type snapshot_cap() ::
        #{version := binary(),
          module := wasm:module_(),
          imports := import_set(),
          init := [{call, binary(), [term()]}],
          validate := fun((wasm:instance()) ->
                              ok | {error, wasm_worker_error:worker_error()}),
          post_restore := fun((wasm:instance(), restore_ctx()) ->
                                  ok | {error, wasm_worker_error:worker_error()})}.


-doc "Load whatever this adapter runs, once, when the worker starts.".
-callback artifact(Opts :: map()) -> {ok, artifact()} | {error, wasm_worker_error:worker_error()}.

-doc """
What this request would need, and what staging it would cost.

Runs in the runner, under the deadline and the heap bound, because sizing a
tenant's request means traversing it and may allocate. It is untrusted work and
is not a pure, allocation-free callback.
""".
-callback requirements(request(), artifact()) ->
    {ok, requirements()} | {error, wasm_worker_error:worker_error()}.

-doc "Build the thing to run. Mounts already exist; limits are already final.".
-callback prepare(request(), artifact(), env()) ->
    {ok, execution_spec(), adapter_state()}
  | {error, wasm_worker_error:worker_error(), adapter_state()}.

-doc "Turn what happened into an answer. Runs in the runner, on the remaining time.".
-callback decode(execution_result(), adapter_state()) -> outcome().

-doc "Release whatever `prepare/3` acquired. Runs in a bounded cleanup job.".
-callback cleanup(adapter_state()) -> ok.

-doc "What this adapter can do, so the conformance kit knows what to demand.".
-callback capabilities(artifact()) -> capabilities().

-doc "Opaque requests the kit submits. Base cases are mandatory.".
-callback conformance_fixtures(artifact()) -> fixtures().

-doc """
Called after **every** invocation, success or trap, and the kernel interprets
none of them.

A WASI exit arrives here as a trap, and only the adapter knows that. A kernel
that told a `proc_exit` trap from any other trap would be calling
`wasi_preview1:exit_code/1`, and a kernel that calls `wasi_preview1` anything
is not language-neutral.
""".
-callback classify(invocation_result(), adapter_state()) ->
    continue | {stop, stop_class()}.

-doc """
How to capture this adapter's runtime once, at `start_link/2`.

An absent callback reads as `unsupported`, so no adapter has to know snapshots
exist. Declaring one is a promise the worker holds it to: a capture that fails
**fails the start**, because the alternative is a worker whose requests invoke
`handle` on an instance that never ran `init`.
""".
-callback snapshot_capability(artifact()) -> unsupported | snapshot_cap().

-optional_callbacks([snapshot_capability/1]).

-doc "Names a configured scratch root. A closed set, supplied at start.".
-type root_id() :: atom().
-doc "The kernel's own id for a request. Minted at `submit`, never a term.".
-type request_id() :: binary().
-doc "What a registered cleanup action is identified by.".
-type token() :: pos_integer().

-doc """
An operation a replacement reaper can replay from disk.

Deliberately a closed set: this is what the journal is allowed to contain, and
the reaper is the only thing that understands it.
""".
-type recover_op() :: {remove_tree, root_id(), binary()}
                    | {delete_file, root_id(), binary()}.

-doc """
What `register/2` accepts.

A fun is in memory and dies with the reaper. A `recover_op()` is written down
and survives it. They are different promises and the caller chooses which.
""".
-type action() :: fun(() -> ok) | recover_op().

-export_type([artifact/0, request/0, adapter_state/0, result/0, outcome/0,
              mount_name/0, mount/0, channel/0, cleanup_cap/0, env/0,
              import_value/0, import_set/0, hook/0, portable/0, capture/0,
              compatibility_key/0, execution_spec/0, execution_result/0, invocation_result/0, stop_class/0,
              requirements/0, capabilities/0, fixtures/0, snapshot_cap/0, restore_ctx/0,
              root_id/0, request_id/0, token/0, recover_op/0, action/0]).
