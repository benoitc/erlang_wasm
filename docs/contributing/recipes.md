# Recipes

One section per kind of change: the files to open, the test that proves it,
and the page to update. Use it after [CONTRIBUTING.md](../../CONTRIBUTING.md),
when you know what you want to change and need to know where. Every recipe
ends with the required checks, which are not repeated here.

```text
pick the recipe -> read what it names -> test that fails -> change
      -> checks -> measure, if you claim speed -> record, document -> PR
```

## Find your recipe

- **Runtime**:
  [an instruction or a proposal](#add-an-instruction-or-a-proposal),
  [an error value](#add-or-change-an-error-value),
  [an option](#add-an-option),
  [an application setting](#add-an-application-setting),
  [memory or the page budget](#change-how-memory-or-the-page-budget-works),
  [the compiled tier](#change-the-compiled-tier),
  [the dispatch path](#change-the-interpreters-dispatch-path),
  [the snapshot format](#change-the-snapshot-format),
  [debug a trap](#debug-a-trap).
- **Components and WASI**:
  [a preview 1 syscall](#add-a-wasi-preview-1-syscall),
  [a WASI 0.2 interface](#add-a-wasi-02-function-or-interface),
  [a WASI 0.3 interface](#add-a-wasi-03-interface),
  [a wasi-nn backend](#write-a-wasi-nn-backend),
  [a canonical or async built-in](#add-a-canonical-or-async-built-in),
  [an HTTP transport](#add-an-http-transport),
  [an implementation behind a behaviour](#replace-an-implementation-behind-a-behaviour),
  [debug a capability refusal](#debug-a-wasi-capability-refusal).
- **Workers**:
  [a language adapter](#add-a-language-adapter),
  [the worker kernel](#change-the-worker-kernel),
  [debug a worker request](#debug-a-worker-request).
- **Tests and fixtures**:
  [rebuild or verify a fixture](#rebuild-or-verify-a-fixture),
  [bump an upstream pin](#bump-an-upstream-pin),
  [debug a failing CI job](#debug-a-failing-ci-job).
- **Project**:
  [a module](#add-a-module),
  [a page](#add-a-page),
  [a dependency](#add-or-upgrade-a-dependency),
  [a new OTP release](#move-to-a-new-otp-release),
  [a speed-up](#claim-a-speed-up),
  [a release](#cut-a-release).

## Add an instruction or a proposal

[Adding an instruction](adding-an-instruction.md) has the four stages and
the files for each opcode space.

## Add or change an error value

Read [Failures are values at the guest
boundary](../design-principles.md#failures-are-values-at-the-guest-boundary)
first. An error is a map with a `class`, a `kind`, a `msg` and a `ctx`, and
nothing a guest supplies may make a call raise.

1. Pick the class from the stage that failed, as the specification suite
   does: `malformed` (it does not decode), `invalid` (it does not validate),
   `link` (it does not instantiate), `trap` (it failed while running) or
   `exhaustion` (it hit a limit). The class decides the constructor:
   `wasm_error:malformed/3`, `wasm_error:invalid/3`,
   `wasm_error:link_error/3`, `wasm_error:trap/2` or
   `wasm_error:exhaustion/2`. Each one throws and does not return.
2. Pick the kind. Callers match on it, so a new kind is a new case in their
   code: reuse an existing kind when the failure means the same thing to a
   caller. Search for the ones in use first, for example
   `grep -rn "link_error(" src`. Trap kinds are the `trap_reason()` type in
   `wasm_error`; add a new one there.
3. Write the kind as a literal atom in the source. A name or a code that comes
   from the guest goes in `ctx`, as a binary.
4. Set `msg` to the specification's text when there is one, because
   `wasm_spec_runner` compares it with what the suite expects. For a trap or
   an exhaustion, `wasm_error` makes the message from the kind: add a clause
   for the new kind beside the others.
5. Make sure the public entry point runs the work inside
   `wasm_error:capture/1` or `wasm_error:capture/2`, and add where it
   happened with `wasm_error:add_context/2`. A key already in `ctx` wins.
6. Write a case that matches `{error, #{class := C, kind := K}}` and watch it
   fail on the code as it is, then run `wasm_prop_SUITE`: `decode_is_total`
   fails if bad input now raises, `decode_creates_no_atoms` if it now makes
   an atom.
7. A worker error is a different type. Its kinds are a closed list,
   `wasm_worker_error:kinds/0`, and `wasm_adapter_conformance` refuses any
   other: add a new one there and to the `kind()` type in
   `wasm_worker_error`.
8. Name the new kind in the guide that describes the failure, so a caller
   knows to match on it.

## Add an option

1. Check it against the rule first: an option says what the embedder knows
   (a limit, a timeout, isolation, whether to compile), never how the runtime
   does it. A tactic that wins only sometimes is chosen from what the runtime
   can observe, or recorded in `test/audit/ATTEMPTS.md` with one default
   shipped.
2. A limit goes in `wasm_limits` and is checked in `wasm`; a worker option in
   `wasm_script_worker`, where a bad value is refused as `{bad_option, Key,
   Why}`.
3. Document it in [Worker configuration](../worker-reference.md) or
   [Hold modules and instances](../embedding.md), with its default, and add
   its row to [Configuration](../configuration.md).

## Add an application setting

An application setting is a key in the `wasm` application environment, and
it applies to the whole node. Most new settings should be something else.

1. Pick the kind of setting from what it says, as
   [Options say what you know](../design-principles.md#options-say-what-you-know-never-how-to-do-it)
   asks:
   - a bound on what one instance's guest may use (work, memory, depth) is a
     limit: see [Add an option](#add-an-option);
   - something the caller of one instance knows (compile it, link it, make it
     capturable) is an instantiate option;
   - a worker's deadline, isolation or byte counts are worker options;
   - something the whole node shares (a budget, a cache size, a directory) is
     an application setting.

   A tactic, such as a cache shape or a chunk size, is none of these.
2. Read it where it is used, with `application:get_env(wasm, Key, Default)`,
   and keep the default in a `-define` beside the read, as `wasm_engine` does
   for `page_limit`. The `env` list in `src/wasm.app.src` is empty: every
   default lives in the code that reads it.
3. Decide when it is read. The module cache and the page budget read theirs
   when the application starts, so a change needs a restart; say so in its
   row.
4. Refuse a value that cannot mean what it says with an error value, as
   `wasm_snapshot_file` refuses a bad size ceiling with
   `snapshot_config_invalid`.
5. Add its row to [Configuration](../configuration.md), in the table for its
   area, with its default and the page that explains it. A setting that is
   not supported API goes under "Internal settings".
6. If a worker or the reaper reads it, add it to the list in
   `every_setting_is_documented` in `wasm_worker_kernel_SUITE`. That case
   fails until [Worker configuration](../worker-reference.md) names it.

## Change how memory or the page budget works

1. Read the module docs of `wasm_memory`, `wasm_keeper` and `wasm_engine`
   first: the keeper is the lifetime authority for anything two instances
   share, and every page is reserved before it is allocated.
2. Run the `wasm_resource_*`, `wasm_budget_SUITE`, `wasm_shared_pages_SUITE`
   and `wasm_paged_memory_SUITE` suites, and `wasm_snapshot_SUITE` if restored
   memories are involved.
3. Memory access is on the hot path: measure it with the
   [protocol](measuring.md), including `realbench` on QuickJS.

## Change the compiled tier

1. Policy (what compiles, and when) is in `wasm_jit`; the code generator is
   `wasm_core`; resident code is `wasm_code_slots`; the disk cache is
   `wasm_code_cache`. The `plugin` and `script` profiles are `defaults/1` in
   `wasm`.
2. If generated code changes shape (what it reads, what a continuation
   carries, which helper it calls), bump `ABI` in `wasm_jit` in the same
   commit and say what an older artifact would do wrong. [Compiled tier
   internals](../compiled-tier-internals.md#bump-the-abi-when-generated-code-changes-shape)
   has the rule and the history.
3. Gate cold compile time and generated code size as well as speed. A change
   that sped up calls once quadrupled compile time because no gate looked.
4. Run `realbench` on QuickJS, five interleaved pairs, both orderings.

## Change the interpreter's dispatch path

Anything in `run/3`, `branch/3` or `do_call/4` in `wasm_exec`. Three changes
there cost about 70% on QuickJS while the synthetic loop measured nothing. Run
`realbench` on QuickJS before you believe any other number; see
[Measuring](measuring.md).

## Change the snapshot format

A snapshot file carries two version numbers in its header, both defined in
`wasm_snapshot_file`. Nothing derives them, so you bump them by hand.

1. Find which number your change moves in the table in [Compiled tier
   internals](../compiled-tier-internals.md#bump-the-abi-when-generated-code-changes-shape):
   - `FORMAT`, read with `wasm_snapshot_file:format_version/0`, when the
     file layout changes: its header or its sections;
   - `IMAGE_ABI`, read with `wasm_snapshot_file:image_abi/0`, when the value
     representation in an image changes, or its set of parts.
2. Bump it in the same commit as the change. A file written with another
   number is refused with `snapshot_format_unknown` or
   `snapshot_abi_mismatch`, and a worker treats that as no image and
   captures a new one. `IMAGE_ABI` is also part of the key
   `wasm_snapshot_store` files an image under.
3. Test it in `wasm_snapshot_SUITE`: an image you write must restore, and a
   damaged one must be refused as a value. The cases named `..._is_refused`
   are the model.
4. Run `wasm_shared_pages_SUITE`. Its case `a_file_from_the_last_release_loads`
   reads `test/fixtures/snapshot/pager-0.8.0.img`, which an older release
   wrote, and fails after a bump. That failure is what users will see: say in
   [Upgrading](../upgrading.md) that images saved by an older release are
   refused and captured again, and update the case and its fixture in the
   same commit.
5. Update [When a file is refused](../snapshots.md#when-a-file-is-refused)
   if the reasons change.

## Debug a trap

1. Read the error value: `class` says which stage failed, `kind` is
   machine-readable, `ctx` says where.
2. If the compiled tier is on, ask it: `wasm_jit:diagnostics/0` for why recent
   compiles were refused or failed, `wasm_jit:dump/1` for an instance's
   generated code.
3. Rerun with a `fuel` limit. Compiled code never runs under fuel, so the
   call is interpreted end to end: a trap that goes away is a generator bug.
4. Pin it with a case, in `wasm_trap_effects_SUITE` if the trap leaves state
   behind.

## Add a WASI preview 1 syscall

1. Add its name to the `Fns` list in `wasi_preview1:imports/2`; that list is
   the import map.
2. Add a `handle/5` clause in `wasi_preview1`. It returns `{errno, E}`, or
   `{errno, E, State}` when it changed the per-instance state; an exception
   becomes `EIO`, never a crash.
3. Put filesystem work in `wasi_fs` and path resolution in `wasi_path`, so the
   sandbox checks stay in one place. Sockets go through `wasi_sock`, and every
   address decision through `wasi_net`.
4. Add a case to the `wasi_*` suite for that area, and one for the refusal: a
   missing capability must answer an errno, not succeed.
5. Add it to "Which syscalls are implemented" in [WASI preview 1](../wasi.md).

## Add a WASI 0.2 function or interface

1. Find the interface's builder in `wasi_preview2` (its module doc has a
   table), or add one returning a map keyed by `{Interface, Field}`.
   `wasi:filesystem` lives in `wasi_p2_filesystem` and `wasi:sockets` in
   `wasi_p2_sockets`; neither calls back into `wasi_preview2`, which would
   add a module cycle.
2. Build each function with `wasm_component:import_fun/2`, giving its
   Canonical ABI signature; `wasm_canon` lifts and lowers the values.
3. Reuse the preview 1 internals (`wasi_fs`, `wasi_net`) rather than writing a
   second sandbox.
4. Merge it into `command/1` if a command component needs it.
5. Test it in the matching `wasm_wasi2_*` suite, and update
   [Components](../components.md) or [WASI preview 1](../wasi.md).

## Write a wasi-nn backend

A backend is not part of this project: it lives in the application that
has the inference engine. [wasi-nn](../wasi-nn.md) has the callbacks.

1. Implement the `wasi_nn` behaviour. Answer `{error, {Code, Message}}` for
   every failure; a raise reaches the guest as `runtime-error` with no
   detail.
2. Bound the time `compute/2` may take. The runtime does not.
3. Free what a graph or a context holds in `close/1`. It is called once for
   each, on the guest's drop or when the instance is destroyed.
4. To change the host side (the grant, the tensor bound, a function of the
   interface), edit `wasi_nn` and add a case to `wasm_wasi2_nn_SUITE`.
   `test/support/wasi_nn_test_backend.erl` is the backend that suite uses.

## Add a WASI 0.3 interface

Read [WASI 0.3](../wasi-0-3.md) and "Where to add things" in [Component
internals](../component-internals.md#where-to-add-things) first.

1. Put small, stateless functions in `wasi_preview3`, beside its `clocks`
   and `random` builders. A larger interface gets a module of its own, beside
   `wasi_p3_filesystem`, `wasi_p3_sockets` and `wasi_p3_http`. Merge its map
   in `wasi_preview3:command/1`; `wasi_preview3:snapshot_hooks/0` then
   declares it too.
2. Key every function `{<<"wasi:pkg/iface@0.3">>, Field}`. A 0.3 import is
   looked up with `@0.3` and never matches a 0.2 key without a version: see
   [Versioned imports](../wasi-0-2.md#versioned-imports).
3. A call that waits is an async import: `{async_import, Sig, Fun}` completes
   at once, and `{async_import, Sig, Fun, {producer, PFun}}` completes when
   the producer says it is done, as `wait-for` does in `wasi_preview3`. Data
   moves through streams and futures: [The async
   ABI](../component-internals.md#the-async-abi) has the host's ends.
4. Keep it in step with 0.2. The two hosts take one options map, which
   `wasi_preview3:command/1` hands to both, so a 0.2 option must mean the
   same at 0.3. Check network access with the same `network` grant through
   `wasi_net`, and mount files with `wasi_preview2:command_mounts/1` and
   `wasi_fs`, as `wasi_p3_sockets` and `wasi_p3_filesystem` do.
5. Test it with wasmtime's program for it, if there is one. Add a case for
   the program to `wasm_wasi3_p3_SUITE`, as `clocks_sleep` is written, and put
   the program in a group in `group/1` and `baseline/0`. Run your case
   before the change, here shown with `clocks_sleep`, and watch the program
   trap or exit non-zero:

   ```sh
   WASM_REQUIRE_WASMTIME_FIXTURES=1 \
     rebar3 ct --suite=test/wasm_wasi3_p3_SUITE --case=clocks_sleep
   ```

   Without the variable a missing program skips, and a skip is green. For a
   behaviour no program covers, write a component by hand, as
   `test/fixtures/component/wasi3keys/` is, and test it in
   `wasm_component_version_SUITE`, which never skips.
6. Add the interface to "What is there" in
   [WASI 0.3](../wasi-0-3.md#what-is-there).

## Add a canonical or async built-in

A canonical built-in is a core function that the Canonical ABI defines, such
as `stream.read` or `thread.yield`. A component asks for one by its opcode in
its canon section.

1. Decode it. Add a clause for its opcode to the `canon` function in
   `wasm_component_link`, returning `{canon_async, Name, Meta}`, with the
   operands the built-in needs in `Meta` (an element type, a slot, `async`,
   `cancellable`). The linker binds every such item through
   `wasm_async:builtin/2`, so the clause is the only linker change. Before
   it, a component that uses the opcode fails to link with kind
   `unsupported_canon_builtin`: that is your failing test.
2. Implement it. Add a clause for `Name` to the private `builtin_1` function
   in `wasm_async`. It returns `fun(Ctx, Flats) -> {ok, Results} | {trap,
   Reason}`. `wasm_async:builtin/2` wraps it, so it traps with `cannot_leave`
   while its instance runs a `realloc` or a `post-return`.
3. Write a component that calls it, as text, under
   `test/fixtures/component/<name>/`, and add it to the list in
   `scripts/build-wat-component-fixtures.sh`. If `wasm-tools` cannot encode
   the built-in yet, write a placeholder and rewrite its opcode, as
   `scripts/forward-opcodes.escript` does for the forwards. The script also
   converts wasmtime's thread scripts, so it needs the wasmtime checkout that
   `scripts/build-wasmtime-p2.sh` makes.
4. Add a case for each behaviour and each trap to
   `wasm_component_async_abi_SUITE` (it reads the `asyncabi` fixture), or to
   `wasm_component_forward_SUITE` for a forward. A thread built-in also runs
   wasmtime's own scripts in `wasm_component_wast_SUITE`. Every command there
   must pass; there is no baseline.
5. Say what it does in [The async ABI](../component-internals.md#the-async-abi).

## Add an HTTP transport

Implement the `wasi_http_transport` behaviour, one `request/2` callback, as
`wasi_http_h1` and `wasi_http_h2` do. A component gets it through the
`http_transport` option of `wasi_preview2:command/1`. Test it beside
`wasm_wasi2_http_SUITE`.

## Replace an implementation behind a behaviour

Three parts of the runtime have more than one implementation. A new one must
pass the same tests as the ones that exist, without a change to the code that
calls it.

| boundary | what you write | what exists | the tests |
| --- | --- | --- | --- |
| `wasm_worker_adapter` | a language for the worker kernel | `wasm_javascript`, `wasm_python`, `wasm_lua`, and the `fake_*_adapter` modules in `test/support/` | `wasm_adapter_conformance`, run from a suite of yours: [Add a language adapter](#add-a-language-adapter) |
| `wasi_http_transport` | the outbound HTTP connection, one `request/2` callback | `wasi_http_h1`, `wasi_http_h2`, and `fake_http_transport` in `test/support/`, which connects to nothing | `wasm_wasi2_http_SUITE`, and `wasm_wasi2_https_SUITE`, which uses the fake: [Add an HTTP transport](#add-an-http-transport) |
| the `wasi_fs` backend | not a behaviour: both backends are in `wasi_fs`, and `wasi_fs:backend/0` says which one runs | `native`, through `wasi_file_nif`, and `fallback`, pure Erlang through `wasi_path` | `wasi_SUITE` and `wasi_nif_SUITE`, on both backends |

- If a new adapter needs a change in `wasm_script_worker`, that is a kernel
  change: see [Change the worker kernel](#change-the-worker-kernel).
- The two file backends must refuse the same escapes. To run the file suite
  on the fallback, build without the NIF, then build it again:

  ```sh
  rm -f priv/wasi_file_nif.so
  CC=false rebar3 ct --suite=test/wasi_SUITE
  rebar3 compile
  ```

- A change to the C side is in [The file NIF](nif.md).

## Debug a WASI capability refusal

A refusal is the host telling the guest it was not granted something. It is
an answer to the guest, not an error to you: your call succeeds, and the guest
sees an error code.

1. Find what the guest got:

   | host | a path outside its grant | an address outside its grant |
   | --- | --- | --- |
   | preview 1 | `ENOTCAPABLE` (76) | `ENOTCAPABLE`, or `EBADF` for a descriptor that is not one of its sockets |
   | 0.2 and 0.3 filesystem | `not-permitted` | |
   | 0.2 and 0.3 sockets | | `access-denied` |
   | `wasi:http`, 0.2 and 0.3 | | `HTTP-request-denied` |

   `ENOTCAPABLE` never means the file is missing (`ENOENT`) or that the
   operating system said no (`EACCES`).
2. Check what you granted. Without `dirs` (preview 1) or `preopen` and
   `preopens` (0.2 and 0.3) there is no filesystem at all. Without `net` or
   `network` there is no network. With `require_native_fs` set and no NIF,
   every directory is refused. A grant the runtime cannot read raises
   `{bad_net_grant, Term}` in your own process, when you build the imports.
3. Ask the check itself. Every path decision is made in `wasi_path` and
   every address decision in `wasi_net`, so you can call them with no guest:

   ```erlang
   {error, 76} = wasi_path:resolve("/srv/app/data", ~"../secret"),
   G = wasi_net:grant(#{connect => [{tcp, ~"10.0.0.0/8", {8000, 8099}}]}),
   true = wasi_net:allows(connect, {tcp, {10, 0, 0, 5}, 8080}, G),
   false = wasi_net:allows(connect, {tcp, {10, 0, 0, 5}, 22}, G).
   ```

   The 0.2 and 0.3 hosts make the same calls: files go through `wasi_fs`,
   which resolves with `wasi_path` or the NIF, and sockets and HTTP through
   `wasi_net`.
4. If you think a refusal is wrong, treat it as a sandbox bug: pin it with a
   case in `wasi_SUITE` or `wasi_net_escape_SUITE` before you change
   anything. [What the sandbox refuses](../wasi.md#what-the-sandbox-refuses)
   and [What the network grant refuses](../wasi.md#what-the-network-grant-refuses)
   list the refusals that are on purpose.

## Add a language adapter

1. Implement the `wasm_worker_adapter` behaviour: `artifact/1`,
   `requirements/2`, `prepare/3`, `decode/2`, `cleanup/1`, `capabilities/1`,
   `conformance_fixtures/1`, `classify/2`, and optionally
   `snapshot_capability/1` and `defaults/1`.
2. If the guest speaks the shared request protocol, build on `wasm_script_v1`
   as the shipped adapters do.
3. Write a suite that delegates to `wasm_adapter_conformance` and passes
   without changing the kernel. If the language needs a kernel change, that
   is [Change the worker kernel](#change-the-worker-kernel).
4. Write the language's page next to [JavaScript](../javascript.md), and put
   any heap floor in [Tuning](../tuning.md).

[Writing an adapter](../worker-contract.md) is the contract in full.

## Change the worker kernel

The kernel is the part of `wasm_script_worker` that every adapter shares: the
worker, the guardian and the runner, the three processes of a request.

1. Read [Worker internals](../worker-internals.md) first. If the change
   touches cleanup, read `test/audit/CLEANUP_STEWARD.md` too: it is the
   reviewed protocol the guardian, the steward and the reaper follow.
2. Find the code through the table in the module doc of
   `wasm_script_worker`, which gives each process's entry and loop. Keep each
   process to its job: the worker never blocks, the guardian owns the
   deadline and the mounts, and only the runner touches the tenant's data.
3. Write the new case in `wasm_adapter_conformance`, not in a suite, so that
   every adapter runs it. A case every adapter must pass goes in its base
   list; a case for a capability goes with that capability.
4. Run it through the fake adapters in `test/support/`.
   `wasm_worker_kernel_SUITE` runs the kit against `fake_typed_adapter`,
   `fake_command_adapter`, the `script_v1` and reactor fakes, and it never
   skips. Watch the new case fail on the kernel as it is.
5. Run the real languages: `wasm_worker_lang_SUITE`, with the reactors built
   as [Get the fixtures for a run](fixtures.md#get-the-fixtures-for-a-run)
   says.
6. If a request now leaves something behind, register it as a cleanup action
   through the guardian, as "A cleanup step" in [Worker
   internals](../worker-internals.md#where-to-add-things) says, and run
   `wasm_cleanup_steward_SUITE`.
7. Every request pays for the kernel. If you claim it costs nothing, time
   the request with `bench/paths/phasing_adapter.erl` and follow the
   [protocol](measuring.md).

## Debug a worker request

1. Follow the request through its processes in
   [Worker internals](../worker-internals.md): worker, guardian, runner.
2. `wasm_script_worker:cleanup_requests/0` lists the requests whose cleanup
   is still owned, with the guardian holding each.
3. `bench/paths/phasing_adapter.erl` wraps a real adapter and times a request
   at each of its adapter boundaries.

## Rebuild or verify a fixture

[Fixtures](fixtures.md) lists every family: its kind, its script, the suites
that read it and how it is checked.

1. For a committed fixture, change its source beside it, run its script and
   commit both: see [Rebuild a committed
   fixture](fixtures.md#rebuild-a-committed-fixture). The snapshot modules
   come from `scripts/build-snapshot-fixtures.py`, the hand-written
   components from `scripts/build-wat-component-fixtures.sh`.
2. For a language runtime, run its fetch or build script again, then check
   what you have:

   ```sh
   scripts/verify-fixtures.sh
   ```

   It checks every file with a `.sha256` in `test/fixtures/lang/` against its
   hash, and that the QuickJS and Lua reactors are present. CI's Integration
   job fails on a missing or mismatched file. A new fetched fixture is checked
   once its `.sha256` is there.
3. Run the suites that read it. If a page needs it, declare it to
   `wasm_docs_SUITE` with `WASM_DOCS_FIXTURES`, as
   [Testing](testing.md#test-the-documentation) shows.

## Bump an upstream pin

Two scripts pin what CI fetches or builds: `scripts/fetch-suites.sh` names
one commit for each upstream test suite, and `scripts/build-wasmtime-p2.sh`
names wasmtime's tag in its `tag=` line. Both check a checkout you already
have against the pin: they move an unchanged one and stop on a changed one, so
changing the pin and running the script is enough. Then update the baselines
the suites keep; never move a suite out of
`wasm_spec_manifest:core/0` to make a build pass. [Bump an upstream
pin](fixtures.md#bump-an-upstream-pin) has the steps for each script.

## Debug a failing CI job

1. Find the job in [What CI runs](../../CONTRIBUTING.md#what-ci-runs): what
   it runs, what it needs and what skips there.
2. A job that is red in CI and green on your machine usually ran something
   your machine skipped. A skip is green, so check your log for skips:
   [Know what skips](testing.md#know-what-skips) lists them. Integration
   runs `wasm_docs_SUITE` with `WASM_DOCS_STRICT=1`, and "wasmtime programs"
   sets `WASM_REQUIRE_WASMTIME_FIXTURES=1`, so a missing fixture fails there.
3. Run the job locally:

   | job | run locally |
   | --- | --- |
   | Compile | `rebar3 compile`, then check that `priv/wasi_file_nif.so` exists: CI fails when the NIF falls back |
   | Tests | `scripts/fetch-suites.sh`, `scripts/fetch-qjs-fixture.sh`, then `rebar3 ct` |
   | Integration | the fixtures in [Get the fixtures for a run](fixtures.md#get-the-fixtures-for-a-run), then `rebar3 ct --suite=test/wasm_worker_lang_SUITE` and the strict run in [Test the documentation](testing.md#test-the-documentation) |
   | wasmtime programs | the commands under "One 0.3 program is slow" in [What CI runs](../../CONTRIBUTING.md#what-ci-runs) |
   | Lint, Xref, Dialyzer | `rebar3 lint`, `rebar3 xref`, `rebar3 dialyzer` |
   | Docs | `rebar3 ex_doc`, reading its output as below |
   | NIF checks | [Run the check build](nif.md#run-the-check-build) and [Run the NIF under a sanitizer](nif.md#run-the-nif-under-a-sanitizer) |
   | NIF under ThreadSanitizer | the emulator build in [What each sanitizer will and will not find](nif.md#what-each-sanitizer-will-and-will-not-find) |
   | Locked dependencies | `scripts/audit-deps.sh` |

   The Docs job fails on any of these words in the output, because
   `rebar3 ex_doc` exits 0 whatever it warns about:

   ```sh
   rebar3 ex_doc 2>&1 | grep -E "warning:|error in doclet|An unknown error"
   ```

4. Know what the caches hold. wasmtime's programs are cached on the hash of
   `scripts/build-wasmtime-p2.sh`, and the build and the Dialyzer PLT on the
   OTP version and the hash of `rebar.lock`. Nothing else makes CI build them
   again.

## Add a module

1. Decide its level in [Architecture](../architecture.md) and add it to the
   level listing; a call upward means a new cycle, which
   `wasm_architecture_SUITE` refuses.
2. Open it with a `-moduledoc` saying what it is.
3. Decide its status: internal, unless users are meant to call it.
4. Give it a line in [Where things are](../map.md), in the table for its
   directory, with that status, and add it to its area's row.
   `wasm_architecture_SUITE` fails on a module the map does not name.
5. Add it to a group in the `ex_doc` section of `rebar.config` that matches
   its status: a group whose name starts with "Internals: " for an internal
   module, or a user group such as "Embedding" or "Workers" for a supported
   one. A supported module also goes in the Supported API list of
   [Start here](../start-here.md#supported-api).

## Add a page

1. Write it task-oriented: what it is and when you need it, then steps.
2. Label every code block with its language; Erlang blocks are parsed and the
   modules they name must exist.
3. Add it to the `ex_doc` extras and groups in `rebar.config`, and to a
   reading path of [Start here](../start-here.md) if a reader needs it on
   the way.

## Add or upgrade a dependency

The runtime depends on two packages: `h1` (the Hex package `erlang_h1`) and
`h2`, the HTTP/1.1 and HTTP/2 stacks behind `wasi:http`. Both are maintained
by this project's author. Add a dependency only when the runtime cannot do
without it.

1. Change the requirement in `deps` in `rebar.config`, then update the lock:

   ```sh
   rebar3 upgrade h2
   ```

2. Commit `rebar.lock` with it. Every CI job keys its build cache on the
   hash of `rebar.lock`, and the Dialyzer job its PLT, so the lock is what
   makes CI build again.
3. Check the locked versions for known advisories and retired releases. The
   Audit workflow, `.github/workflows/audit.yml`, runs the same script on
   every pull request and every Monday:

   ```sh
   scripts/audit-deps.sh
   ```

   A test-only dependency, such as `proper` in the `test` profile, is not in
   the lock. Name it instead: `scripts/audit-deps.sh proper 1.4.0`.
4. A new runtime dependency is also an OTP application: add it to
   `applications` in `src/wasm.app.src`.
5. Fix a bug in `h1` or `h2` in that library, release it, and bump the
   requirement here. Do not work around it in `wasi_http_h1` or
   `wasi_http_h2`.
6. Run `wasm_wasi2_http_SUITE`, `wasm_wasi2_https_SUITE`,
   `wasm_wasi2_http_limits_SUITE` and `wasm_wasi2_serve_SUITE`, then the full
   `rebar3 ct`.

## Move to a new OTP release

1. Change the version everywhere it is pinned, in one commit:
   - `OTP` in `.github/workflows/ci.yml` and `.github/workflows/audit.yml`,
     a major version such as `'29'`;
   - `OTP` in `.github/workflows/tsan.yml`, an exact release, because that
     job builds the emulator, and the `OTP-29.1.2` tag in [The file
     NIF](nif.md), which tells you to build the same one;
   - "Erlang/OTP 29 or later" in [Getting started](../getting-started.md)
     and the comment above `OTP` in `ci.yml`, if the minimum moves.
2. Run the required checks. The build cache and the Dialyzer PLT are keyed
   on the OTP version, so CI builds both again.
3. Check the compiler defect in [Values a multi-value let must not leave
   unused](../compiled-tier-internals.md#values-a-multi-value-let-must-not-leave-unused).
   `an_unused_access_result_never_clobbers_a_used_one` in
   `wasm_paged_memory_SUITE` guards the way `wasm_core` avoids it. Simplify
   that ordering only if the new release fixes the defect, and the case must
   still pass under both compile qualities.
4. Check `test/audit/UPSTREAM-OTP.md`. If `compile:forms/2` can now bound or
   link the process it compiles in, `wasm_core` may no longer need to run
   the compiler in a process of its own, bound by `wasm_lifetime:bind/1`.
   Measure before you remove it.
5. Use only documented OTP APIs: an undocumented one is what a new release
   changes without notice. On an upgrade, recheck the measured exceptions
   `wasm_architecture_SUITE` lists, since those are the calls it can break.

## Claim a speed-up

[Measuring](measuring.md): fix the gates first, measure, and add the result
to `test/audit/PERF.md` in the same commit. A dropped idea goes in
`test/audit/ATTEMPTS.md`.

## Cut a release

1. On a `release-X.Y.Z` branch, rename `## Unreleased` in `CHANGELOG.md`, add
   a short intro, bump `vsn` in `src/wasm.app.src`, and add upgrade notes to
   [Upgrading](../upgrading.md) if anything breaks.
2. Open a pull request; merge when CI is green.
3. Tag `main` with an annotated `X.Y.Z` tag, and create the GitHub release
   with the changelog section as its notes.
4. The maintainer publishes to hex with `make publish`.

## Read this next

[Testing](testing.md), then [Measuring](measuring.md) if your change claims
speed or memory.
