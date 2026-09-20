# The cleanup steward protocol

The design record for the worker cleanup rework. This is the reviewed artifact
that the implementation follows; it is committed first, before any behaviour
change, so the protocol can be reviewed on its own.

## Problem

The guardian (one process per in-flight request, in `wasm_script_worker`) calls
the singleton reaper synchronously: `reserve`, `register`, `withdraw` and
`transfer` are `gen_server:call(..., infinity)`, and the reaper writes and
`fsync`s its journal inside those calls. While the guardian is blocked there it
is not in its `receive ... after remaining(deadline)`, so a slow journal or a
dead reaper suspends deadline enforcement for the request; a reaper death
mid-`register` also spends up to 30 s in `unreachable/1`.

A bare timeout on the call is not a fix: a timed-out `gen_server:call` leaves
its message in the reaper's mailbox to run later, so cleanup ownership becomes
unknown, and a durable operation must not be treated as reaper-owned until an
acknowledgement proves it is in durable storage.

## Roles and supervision

Four roles.

- **Guardian** — owns execution, output, cancellation and the request deadline.
  It never calls or waits for the reaper. It retains the **complete** bounded
  cleanup mirror until `finish` is accepted by the reaper or a terminal
  replacement steward acknowledges ownership.
- **Cleanup steward** — one per request. Owns the complete cleanup mirror and
  the operation ledger. Not linked to the guardian, but the guardian and steward
  monitor each other; the reaper monitors the steward instead of the guardian.
- **Cleanup manager** — node-wide. Performs no filesystem I/O and invokes no
  cleanup callback. It bounds steward admission, grants cleanup-job leases,
  monitors stewards, and supplies the operator view.
- **Reaper** — owns the replicated registry and journal. Runs cleanup only after
  an explicit `finish` barrier or after both volatile owners are dead.

`wasm_worker_sup` becomes `rest_for_one` and starts, in order:
`wasm_cleanup_steward_sup`, `wasm_cleanup_manager`, then `wasm_worker_reaper`
when configured at application start (lazy start remains supported).

Each steward is a temporary dynamic child keyed `{cleanup_steward, RequestId}`;
the manager starts and monitors it. On a manager restart it rebuilds its steward
count from `supervisor:which_children/1`, never assuming zero. A steward-sup
failure terminates its stewards and restarts the manager and reaper; the
ownership rules below make that unable to authorise cleanup while a guardian and
runner are still active.

## Capacity

The manager admits at most `max_cleanup_jobs + cleanup_queue_len` requests in
`reserving`, `live`, `finishing`, `reaper_cleanup` or `local_cleanup`. The
capacity is one internal settings function shared with the reaper
(`setting_keys/0`, `max_cleanup_jobs + cleanup_queue_len`), not two independent
limits.

Admission is a manager-owned record keyed by `RequestId`, independent of any one
steward pid. It is reserved before the first steward starts. Steward DOWN
transitions the admission to `owner_lost`; it does not release it. Admission is
released only when:
- reserve was definitively rejected and neither the reaper inventory nor a live
  steward holds the `RequestId`;
- reaper-owned cleanup removed the record and the terminal steward exited;
- cleanup reached quarantine and no active steward or job remains; or
- local cleanup completed and a later replacement reaper replayed and removed
  the retained journal record.

Starting a terminal replacement steward **transfers** the existing admission; it
never releases and reacquires.

Recovered journal records without a live steward also consume capacity. During
reaper startup, new admission stays closed until the reaper reports its recovered
record count to the manager.

**Cleanup-job grants are leases**, keyed `{OwnerPid, OwnerGeneration, RequestId,
LeaseRef}`, so a slot cannot be stranded by a reaper that dies after a grant but
before starting or reporting its job. The manager monitors every lease owner: a
reaper-owned lease is released when that exact reaper pid dies (a replacement
generation never inherits it); a local-cleanup lease is represented by the
terminal steward's `local_cleanup` state and reconstructed on manager recovery;
an explicit completion releases only the matching `LeaseRef`. The manager's
recovered request count is the **union by `RequestId`** of live stewards,
terminal replacement stewards and the current reaper inventory, never their sum.

Both reaper cleanup jobs and local fallback jobs acquire `max_cleanup_jobs`
slots from the manager, so a reaper outage cannot create an unbounded burst.

## Manager recovery (`recovering | ready`)

On start or restart the manager closes admission and grants. It enumerates every
steward child, asynchronously requests each one's state, and counts each
`local_cleanup` steward as one job slot. Because the manager precedes the reaper
under `rest_for_one`, its failure also restarts the reaper; it still waits for
the replacement reaper's complete post-sweep inventory before entering `ready`.
It tracks one exact `{ReaperPid, Generation}`; updates from an older pid or
generation are ignored, and a new generation atomically replaces the recovered
inventory. Admission and grants open only after all live stewards have replied
and the current reaper has supplied its inventory; silence keeps it closed.

## Load-bearing invariants

1. The guardian never waits for cleanup replication or journal I/O.
2. Only the steward sends new-protocol state mutations to the reaper.
3. The reaper records and monitors both guardian and steward.
4. Steward DOWN alone never authorises cleanup while the guardian may still run.
5. The guardian records an unacknowledged action or adapter state before
   forwarding it to the steward.
6. The steward records the same state before sending it to the reaper.
7. Every mutation has a stable operation id and a stored result.
8. Neither the steward nor the reaper ever **blocks** on the other: operations
   use non-blocking `send_request`/`check_response`, and recovery/adoption uses
   asynchronous messages. The reaper's `handle_call` may spend time in journal
   I/O, but that only leaves an operation pending; it never suspends the
   steward's or the guardian's loop.
9. Registered actions and `Adapter:cleanup/1` must be idempotent and safe to run
   concurrently: a reaper can die after an external effect and before recording
   completion, so exactly-once execution of an arbitrary side effect cannot be
   promised.
10. Ambiguous ownership resolves toward retaining state, never deleting a
    possibly live request directory.

## Bootstrap

The worker computes the absolute deadline before spawning the guardian. The
guardian immediately enters a booting receive loop handling worker DOWN,
cancellation, steward DOWN, the reserve result and the deadline. It asks the
manager to start the steward; the manager refuses with `cleanup_saturated` when
admission is full and `no_reaper` when no reaper can accept a reservation.

Reserve is operation sequence 0; the guardian creates no directory until the
steward reports reserve accepted. For a finite timeout the guardian-ready wait
uses the same remaining deadline and returns the named timeout error, not the
generic "request did not start"; `timeout => infinity` keeps the startup
watchdog. If the deadline expires before reserve is resolved, the guardian
reports timeout and exits, the worker slot is released, and the steward retains
admission and waits for reserve's acceptance or rejection — if accepted it
finishes and cleans the reservation, if rejected it exits and admission is
released. There is no transition where an accepted reservation has no owner.

## Routing

The runner keeps sending `register`, `withdraw` and `deliver_state` to the
guardian. The guardian makes no synchronous reaper call: for each request it
allocates a local correlation reference, stores any new action or adapter state
in a bounded pending map (bounded by `max_cleanup_actions`), forwards the request
to the steward, and returns to its deadline loop. The steward assigns an
operation sequence and sends the eventual result back; the guardian drops the
pending entry and replies to the runner. `stage` and `mounts` stay in the
guardian — request-local work, not reaper mutations.

## Terminal ordering and ownership handoff

The guardian keeps its complete mirror (bounded by `max_cleanup_actions`) until
cleanup ownership is acknowledged. On result, cancellation, deadline or worker
death it: kills or observes the runner (PR 5 runner state); waits for the DOWN
only when it has not already consumed it; drains cleanup messages the runner sent
before its DOWN and forwards them to the steward; publishes the outcome; deletes
the channel tables and **releases the worker slot**; sends `complete` to the
steward; and enters a **non-blocking cleanup-handoff receive loop**. Publishing
and freeing the slot happen before handoff, so the guardian stays
deadline-responsive even when the reaper is unavailable. After publishing, the
guardian demonitor-flushes the worker, so a later worker shutdown is no longer a
cancellation event and cannot publish a second outcome.

The guardian exits only after the steward reports that `finish` and every lower
operation were accepted by the reaper; acknowledging `complete` is not enough,
because the mirror is still needed if the steward dies before the reaper accepts
a pending op. If the steward dies before that acknowledgement, the guardian keeps
the complete mirror and asks the manager to start a **terminal replacement
steward** in `local_cleanup` under the same `RequestId` with the mirror; the
manager transfers the existing admission, and the replacement confirms it stored
the mirror before the guardian exits. If the manager is recovering, the guardian
stays in the handoff loop and retries without blocking result publication;
admission was already charged, so these post-result guardians stay bounded.

### Steward failure while execution is live or handoff is pending

If the steward dies while the guardian is alive: the reaper enters `owner_lost`
and stays passive; the guardian observes steward DOWN, kills or observes the
runner, drains earlier cleanup messages, publishes an internal cleanup-owner
failure if no outcome was published, asks the manager to transfer admission to a
terminal replacement steward, transfers its complete mirror, and exits only after
the replacement confirms ownership. The manager does not release admission merely
because the original steward died. Previously acknowledged state may also exist
in the reaper; duplicate or concurrent cleanup here is permitted only under the
idempotent, concurrent-safe contract.

### Guardian failure

If the guardian dies while the steward lives, the reaper stays passive and
notifies the steward; the steward enters `finishing`, reconciles pending
operations, and submits `finish`. If both are dead, the reaper owns cleanup from
its replica and durable journal.

## Operation identity and transport

The steward assigns monotonic `OperationId = {RequestId, Sequence}`. Reserve is
sequence 0; for `register` the sequence is also the cleanup token, removing the
reaper-generated token and making retries deterministic. The steward ledger is
`OperationId => {Operation, pending | {done, Result}}`.

State-changing operations use `gen_server:send_request/2` against the exact
reaper pid, so the caller identity is authenticated by OTP rather than carried as
a spoofable field:

```text
ReqId = gen_server:send_request(ReaperPid,
                                {apply, RequestId, OperationId, Operation})
```

The steward stores `ReqId` with the operation and keeps running its loop,
inspecting responses with `gen_server:check_response/2`; it never calls the
blocking `receive_response/2`. The reaper handles the operation in
`handle_call/3`, where the real caller pid in `From` must equal the steward pid
registered for the request (reserve establishes that identity; every later
operation must match it). A request is sent once to that pid: a silent reaper
leaves it pending, and reaper termination surfaces as a request error that
triggers replacement adoption — no timeout retry against the same pid. Responses
from an old reaper pid or generation are discarded.

The reaper processes operations in sequence order. A gap does not mutate state;
it asks the steward to resend the missing sequence. An exact duplicate returns
the stored result. After `finish` is accepted, exact duplicates keep returning
stored results, and a new higher operation is rejected `request_finished` and
cannot recreate the request.

### Operation-ledger bound

`max_cleanup_actions` bounds currently owned actions but not completed
register/withdraw cycles, so a separate `max_cleanup_operations_per_request`
(default 256) is enforced identically by steward and reaper. `reserve` and
`finish` do not consume it; `register`, `withdraw` and `transfer` each consume
one sequence. Once exhausted: `register` runs the unaccepted action through
bounded cleanup and returns `released`/`cleanup_failed`; `withdraw` returns a
named refusal and leaves the action `owned`; `transfer` returns a named refusal
and leaves adapter state and actions in the guardian mirror; `finish` is still
accepted, so exhaustion can never block terminal cleanup.

Exhaustion is sequence-safe: an over-limit request receives no `OperationId` and
creates no sequence gap, so `finish` uses the next contiguous sequence. The first
over-limit mutation transitions the request to `finishing` and the guardian
terminates the runner, so an adapter cannot generate unlimited over-limit
attempts. For an over-limit `register`, the guardian's mirror retains ownership
while the steward obtains a manager-controlled cleanup-job lease; the callback
runs under the normal callback and job deadlines; the response is `released` only
after completion and `cleanup_failed` only after the bounded attempt fails, and
`finish`/handoff wait for it. Over-limit `withdraw`/`transfer` are refused locally
without changing ownership. Every callback spawned because of exhaustion counts
against `max_cleanup_jobs`.

## Operation behavior

| Operation | Steward before sending | Reaper before success | Definitive failure |
| --- | --- | --- | --- |
| reserve | stores guardian, root and relative path | writes and renames the base v2 journal, installs both monitors | returns named refusal; steward exits |
| register recover_op() | stores action as `owned` | rewrites journal with operation id and token | executes allowlisted operation bounded; returns `released` or `cleanup_failed` |
| register fun | stores action as `owned` | stores same token and closure in memory | runs closure bounded; returns `released` or `cleanup_failed` |
| withdraw | marks `withdraw_pending` but retains action | removes action; durable removal rewrites journal | restores `owned`; returns error |
| transfer | stores adapter state as `transfer_pending`; actions stay `owned` | stores state and marks actions transferred | retains state and owned actions for terminal fallback; returns error |
| finish | requires every lower sequence resolved | stores result, authorizes cleanup, retains request and ledger | remains `finishing`; resubmits only after replacement adoption |

The register contract is unchanged (`wasm_worker_reaper.erl:247`): `{ok, Token}`
means steward and reaper accepted ownership, `{error, E, released}` the action
completed, `{error, E, cleanup_failed}` the action is unowned. A speculative
local state change never produces public success. Transfer success changes both
copies from `owned` to `transferred` before the success result is sent.

## Durability

The journal encodes only the closed `recover_op()` set — `{remove_tree, _, _}`
and `{delete_file, _, _}` (`is_durable/1`) — and `wasm_worker_adapter.erl:268`
distinguishes those from a bare `fun/0`. **An Erlang closure cannot be
journalled.** So the guarantees are:
- exactly one logical owner at a time;
- durable `recover_op()` actions run at least once and may be replayed after an
  uncertain crash (idempotency makes replay safe);
- **function actions and adapter state are best-effort**: preserved across a
  reaper-only crash by the surviving steward, lost only if both volatile owners
  die or the node terminates;
- controlled timeout and late-reply paths do not duplicate execution.

Exactly-once of an arbitrary side effect across a crash between running it and
recording completion is impossible, and the note does not claim it; tests assert
exactly-once only for controlled suspend/resume and late-reply cases.

## Steward state machine

```text
reserving -> live -> finishing -> reaper_cleanup -> done
finishing -> local_cleanup -> done
```

- `reserving`: reserve sequence 0 is pending.
- `live`: execution is active and mutations are accepted.
- `finishing`: `complete` or guardian DOWN observed; earlier operations are
  reconciled and no new operation is accepted.
- `reaper_cleanup`: finish acknowledged; the steward is a passive mirror.
- `local_cleanup`: the reaper is confirmed unavailable and the manager granted a
  cleanup slot.
- `done`: cleanup completed or reached quarantine; the steward exits.

The steward stays alive through `reaper_cleanup`, preserving closures and adapter
state across a reaper-only crash. A passive mirror never executes while the
active owner is alive.

## Reaper ownership state machine

Three independent dimensions:

```text
execution: guardian_alive | guardian_down
owner:     steward_alive | steward_down
cleanup:   passive | authorised | queued | running | complete | quarantined
```

| Event | Required action |
| --- | --- |
| guardian DOWN, steward alive | notify steward and remain passive |
| steward DOWN, guardian alive | enter `owner_lost`, notify guardian, never clean |
| guardian and steward both DOWN | authorize cleanup from replica and journal |
| valid finish from live steward | store result, acknowledge once, authorize cleanup |
| cleanup completes, steward alive | retain journal and tombstone; send `cleanup_complete` |
| cleanup completes, steward already down | remove journal record and tombstone |
| steward DOWN after cleanup complete | remove journal record and tombstone |
| retries exhausted | quarantine journal, send `cleanup_terminal`, permit steward exit |

A finish barrier does not delete the request record. The terminal tombstone is
removed only after cleanup is complete and steward DOWN has been processed;
because a steward's signals precede its monitor DOWN, no earlier operation can
arrive after tombstone removal — this closes the late-request case, not only the
late-reply case.

## Cleanup execution and fallback

Reaper jobs and local fallback jobs use the same manager-controlled global job
limit. Every callback runs in its own monitored child with `cleanup_timeout`; the
whole job retains `cleanup_job_deadline`. Execution order stays: `Adapter:cleanup/1`;
owned action callbacks; transferred action callbacks only when adapter cleanup
failed; durable filesystem operations.

No guardian event-loop path synchronously waits for cleanup beyond the remaining
deadline. The old fallback ran a function action through `unreachable/1`'s
`run_bounded` up to `?CLEANUP_TIMEOUT` (30 s), which would reproduce the wedge in
another branch; fallback cleanup is now detached with transferred ownership (the
terminal steward) or bounded by the remaining deadline with the unresolved state
retained.

Local cleanup has exactly two authorization paths:
1. **Reaper loss** — the steward observed DOWN for the exact reaper pid, the
   manager could not establish a replacement through
   `wasm_worker_sup:ensure_reaper/0` (it returned an error, or the reaper is
   suspended and no replacement registered), the request is terminal, and the
   manager granted a cleanup-job lease. A timeout against a still-live reaper
   never authorizes this.
2. **Steward loss** — the original steward died, the guardian killed or observed
   the runner, drained its messages, and transferred its complete mirror to a
   terminal replacement steward. Permitted even if the reaper is alive, because
   the reaper may hold acknowledged state while the guardian mirror holds an
   operation whose acceptance is unknown. Duplicate cleanup is covered by the
   idempotent, concurrent-safe contract.

If `wasm_worker_sup` collapses while the guardian survives, volatile state is not
lost: the guardian keeps the complete mirror and hands it to the replacement
manager after the subsystem restarts. Volatile state is lost only if both
guardian and steward die before the reaper accepted it; durable journal
operations remain recoverable. An old cleanup job may briefly outlive its dead
reaper, so local fallback depends on the idempotent, concurrent-safe callback
contract. A durable journal record is left for a later replacement.

## Reaper restart and asynchronous adoption

During sweep a replacement reaper sends `{adopt_request, ReaperPid, Generation,
RequestId}`. A live steward replies `{adopt_reply, RequestId, GuardianPid,
LastSequence, Ledger, Actions, AdapterState, StewardState}`. The reaper validates
the request id, guardian pid and steward pid, combines journalled durable results
with the steward ledger, reconstructs volatile actions and adapter state, and
replies `adopted`. Only after `adopted` does the steward resend operations still
unknown. No synchronous reaper-to-steward or steward-to-reaper call is permitted
during adoption; silence becomes `held` and never authorizes replay. If the
steward is dead, the replacement replays only durable `recover_op()` entries.

## Journal v2

The journal remains an atomically replaced whole record:

```text
v2 <incarnation> <generation> <guardian-pid> <steward-pid> <request-id>
reserve <sequence> <root> <path>
register <sequence> <token> <verb> <root> <path>
withdraw <sequence> <token>
```

Only fixed verbs decode; no journal field can mint an atom. A current-incarnation
v2 record is classified: steward alive -> challenge and adopt, do not replay on
silence; steward dead and guardian alive -> monitor and handshake the guardian,
hold; both dead -> replay durable operations; a different incarnation -> both pids
are meaningless, replay durable operations.

## Journal v1 and upgrades

The v1 decoder keeps the existing guardian handshake. A same-incarnation v1
record naming a live guardian is never an orphan merely for lacking a steward; it
stays `legacy_live`/`legacy_held` until the guardian terminates or denies
ownership. The reaper keeps compatibility handlers for legacy `register/2`,
`withdraw/2`, `transfer/3` and `finish/1` from guardians still on old code.

An already-running 0.4.1 guardian cannot expose its private in-process closure
and adapter-state mirror to new code, so the safe upgrade behaviour is: never
delete its directory while it remains live; retain and replay its durable journal
operations after it terminates; accept new legacy operations while it remains
live; and document that pre-upgrade volatile closures and adapter state keep the
old best-effort guarantee. To preserve every volatile action during deployment,
drain active v1 requests before replacing the reaper module. This limitation
applies only to requests already on old code; every request the new version
starts uses v2 and the steward protocol. A dead-owner or different-incarnation v1
record is replayed through its existing allowlisted durable operations.

## Operator view

`cleanup_stats/0` and `cleanup_requests/0` read the cleanup manager instead of
an infinite call to the reaper. The manager reports admitted and available
capacity, request id, guardian and steward pids, steward state, last known reaper
generation, pending operation count, cleanup state, recovered orphan count and
quarantine count. The reaper pushes generation, recovery, state and quarantine
changes to the manager asynchronously, so diagnostics stay bounded while the
reaper is stuck in journal I/O.

## Measurement border

PR 6 adds a per-request steward spawn and a manager admission handshake to the
request path, so it is measured against the PR 5 baseline. The guest execution
envelope must not move (only `src/worker/` cleanup ownership changes): the
`phases pairs` invocation envelope and interpreter/tier coverage stay within
`[0.95, 1.05]`. The accept phase (T0-T1, already 1.2-2.0 ms) is where the new
cost lands and is measured before/after, interleaved, minimums, load recorded; if
it exceeds the gate, the admission handshake folds into the reserve round-trip
rather than adding a second hop. Latency and throughput arms pass `[0.95, 1.05]`,
null-gated first. Every number and the per-request process count go into
`test/audit/PERF.md`.

## Required tests

Each is first run against its parent commit and must fail for the intended
reason.

1. Suspend the reaper during reserve; the finite deadline returns timeout, the
   guardian exits, and later reserve acceptance is cleaned.
2. Repeat submissions while reserve is suspended; steward count stops exactly at
   capacity and no extra reaper operations accumulate.
3. Kill the steward while the runner is active; cleanup does not start until the
   guardian has killed or observed the runner.
4. Kill the steward with register unacknowledged; the guardian mirror releases
   the action.
5. Kill the steward with transfer unacknowledged; the guardian mirror retains and
   cleans adapter state.
6. Queue register before cancellation and runner DOWN; the guardian drains and
   forwards it before `complete`.
7. Reject register definitively; it returns exactly `released` or
   `cleanup_failed`.
8. Reject withdraw definitively; local ownership is restored.
9. Reject transfer definitively; adapter state and owned actions remain available
   for fallback.
10. Submit a durable register and kill the reaper before dequeue, after journal
    rename, and after result send; retry uses the same id and token.
11. Register a closure and transfer adapter state, then restart the reaper;
    adoption restores both while the steward lives.
12. Cross steward retry with reaper adoption; no synchronous call cycle or
    deadlock.
13. Kill the guardian before and after every operation acknowledgement.
14. Accept finish, then kill the reaper before cleanup starts.
15. Kill the reaper during an authorized cleanup job; its slot becomes reusable.
16. Kill the reaper after callbacks but before `cleanup_complete`.
17. Run the adapter cleanup conformance fixture twice and concurrently.
18. Submit an exact duplicate after finish; it returns its stored result.
19. Submit a new higher operation after finish; it returns `request_finished` and
    does not recreate state.
20. Remove the tombstone only after cleanup and steward DOWN.
21. Restart from a same-incarnation v1 record with a live guardian; the request
    directory is untouched.
22. Restart from dead-owner and different-incarnation v1 and v2 records; only
    allowlisted durable operations are replayed.
23. Terminate the exact reaper and make `ensure_reaper/0` return an error while
    the manager stays alive; finish multiple stewards and prove local cleanup
    concurrency never exceeds `max_cleanup_jobs`.
24. Suspend the reaper and call the operator APIs; both return the bounded manager
    view.
25. Verify the guardian initiates runner termination at the deadline and publishes
    the result within the bounded PR 5 kill grace, with the reaper suspended
    throughout adding no latency; the steward may remain without occupying the
    worker slot.
26. After reaper-owned cleanup, verify nothing remains; after local fallback,
    verify volatile state and scratch resources are gone but the durable journal
    remains until a replacement reaper replays and removes it.
27. Kill the manager during both reaper cleanup and local cleanup; capacity and
    job concurrency stay bounded.
28. Publish an outcome with an operation still pending, then kill the steward
    before finish is acknowledged; the guardian remains after publication,
    transfers the complete mirror, and the resource is cleaned.
29. Restart the manager during that handoff; the guardian retains the mirror, the
    `RequestId` stays charged exactly once, and handoff completes after recovery.
30. Churn register/withdraw past `max_cleanup_operations_per_request` while one
    action stays live; the ledger and process memory stay bounded and `finish`
    is still accepted.
31. Terminate and restart `wasm_worker_sup` while an operation is pending; the
    guardian retains the complete mirror, transfers it after recovery, and the
    resource is cleaned without reopening the worker slot.

## How this lands safely

This rewrites the live cleanup path for untrusted requests, where a subtle bug
means a leaked directory or a double-executed cleanup, so it lands under a
tighter discipline than a feature change.

**Strangler, not big-bang.** The steward arrives first as a behaviour-preserving
relay, then semantics shift one operation at a time. Each commit is either
byte-for-byte identical behaviour (a refactor) or one small tested delta, never
both. The reaper's legacy `register/2`, `withdraw/2`, `transfer/3`, `finish/1`
stay untouched throughout, so the new `{apply, ...}` path is additive and a
rollback is "stop routing through the steward"; a v1 request never notices.

Commit order, each green before the next:
1. Guardian calls the reaper *through* the steward as a synchronous relay:
   topology in place, behaviour identical.
2. `register`/`withdraw`/`transfer` become async forwards: the guardian stops
   blocking, holds a pending map keyed by correlation, and relays the reply.
   This is the one real behaviour change and it is isolated.
3. The op-id ledger and the `send_request`/`check_response` transport.
4. Terminal handoff: publish and free the slot, then `complete`, then wait for
   the steward's acknowledgement.
5. Journal v2 and adoption.
6. The v1 compatibility path.
7. The boundary tests and the measurement.

**Seams before logic.** The dangerous cases are interleavings, so the
fault-injection points are first-class, never `timer:sleep`: a fake reaper the
test acks/hangs/kills on command, a per-operation injection point so a test can
kill the reaper "after journal rename, before reply" deterministically, and the
manager and steward addressable so a test can kill them at a boundary.

**Tests are the spec, written first, failing first** (`AGENTS.md`). The
north-star regression is written first: a stuck reaper while a request runs,
asserting the guardian still fires its deadline; it is red on today's code (the
wedge) until commit 2. Every boundary test is written before the commit that
satisfies it, run against the parent, and shown to fail for the intended reason.
The load-bearing invariants are encoded as observable state (the manager's
counts, `sys:get_state`, monitors), not comments, so a violation is caught and
the guard goes red on the broken build.

**Isolation and determinism.** Every test that kills a process runs in a peer
node, so a hang in a broken interleaving cannot wedge the CT run. Synchronisation
is explicit -- ack-on-message, monitors, `sys:get_state`, barriers -- never a
sleep used as a barrier.

**Measure and gate.** The accept phase (T0-T1) and the invocation envelope are
measured before/after with the interleaved `phases`/`workerbench` protocol,
null-gated `[0.95, 1.05]`, recorded in `test/audit/PERF.md`; the deadline test
proves latency is unchanged with a stuck reaper. Nothing raises, files are staged
by name, commits are concise with no attribution lines.

## Architecture

Three new modules (`wasm_cleanup_steward`, `wasm_cleanup_steward_sup`,
`wasm_cleanup_manager`) take the count from 68 to 71, added to
`docs/architecture.md`. To avoid a new xref cycle: cleanup-setting defaults,
validation and normalisation stay in `wasm_worker_reaper` as pure exported
functions that `wasm_worker_sup` and `wasm_cleanup_manager` call;
reaper-to-manager updates and lease requests use plain pid messages or
`send_request` to an exact pid, never a remote call to `wasm_cleanup_manager`.
That makes edges toward the reaper but no reaper-to-manager edge, so the three
cycles the architecture suite already asserts gain no fourth.
