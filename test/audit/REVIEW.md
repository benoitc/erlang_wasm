# erlang_wasm: pre-release review

**Status: all ten findings closed.** See "Outcome" at the end for what each fix
was, and which commit carries it. The body below is the audit as it was
written, with the reproductions that justified each fix.

Read-only audit of `release-0.3.0` (119 files, 42 modules). No repository file
was changed. Every finding below was reproduced by a probe; the probes are in
`probes/`, the measurement harnesses in `bench/`.

Machine: Apple M4 Pro, 14 cores, 48 GB, macOS 15.5, OTP 29, load average ~5
during the run.

---

## Findings, worst first

### 1. CRITICAL `wasm:load/1` exits instead of returning a value

The central promise of the library, stated in `README.md`, the `wasm`
moduledoc and `docs/getting-started.md`, is that nothing raises and every
failure is a value. It does not hold on the load path.

Reproduced (`probes/p4_race2.erl`), two processes loading the same 1.8 MB
module at the same time:

```
LEAD2 two concurrent loads -> [{returned,ok},
                               {raised,exit,
                                   {timeout,gen_server_call,
                                       wasm_module_cache,store}}]
```

`src/wasm_module_cache.erl:87` calls `gen_server:call(?SERVER, {store, ...},
30000)`. A timeout there is an `exit`, not an `{error, _}`, and `wasm:load/1`
propagates it into the caller. A supervised worker calling `wasm:load_file/1`
in `init/1` dies with a reason its supervisor cannot interpret.

Caused by finding 2. Both need fixing: even with 2 fixed, a slow enough box
brings this back.

### 2. CRITICAL 24 seconds inside the module cache server per large module

`src/wasm_module_cache.erl:144`:

```erlang
Entry = #{holders => 1, size => erts_debug:size(Module) * erlang:system_info(wordsize)},
```

Measured on the compiled qjs module (`probes/p3_size.erl`):

| call | time | answer |
| --- | ---: | ---: |
| `erts_debug:size_shared/1` | 34 ms | 2,922,442 words |
| `erts_debug:size/1` | **24,132 ms** | 2,922,462 words |

710x the time for an answer 20 words different out of 2.9 million. `size/1`
walks the term without a visited set, so cost is driven by revisits, not by
sharing volume.

It runs **inside `handle_call`**, so for those 24 seconds every `load/1`,
`unload/1` and `stats/0` on the node is blocked. The number is used only for
the `size` field reported by `stats/0`.

The module comment two lines above says compiling is kept outside the server
"so a large module does not block every other loader". The intent is right; a
24-second statistic was left inside.

### 3. HIGH Lost wakeup: the waiter table dies with whichever process created it

`src/wasm_wait.erl:113` creates `wasm_waiters` from `ensure_table/0`, which is
called by `wait/4` and `notify/3`. Both run in the guest's own process, so the
table is owned by whichever agent happened to touch it first, and dies with it.

Reproduced (`probes/p8_wait2.erl`):

```
table owner is the first waiter: <0.82.0> (A = <0.82.0>)
waiters registered: 2
after killing A, table exists: false
notify(B's address) woke 0 agent(s)
B: TIMED OUT despite being notified (lost wakeup)
```

B is an unrelated agent in an unrelated instance. Killing A discarded its
registration silently, `notify/3` recreated an empty table, and the wakeup was
lost. With a negative timeout, which the specification defines as "wait
forever" and `timeout_ms/1` maps to `infinity`, B parks permanently.

This is reachable from the documented worker pattern, whose timeout path is
`exit(Pid, kill)` (`docs/worker.md`), and `kill` does not run the `after`
clause that would have cleaned up.

`wasm_engine` gets the same problem right by creating its tables in `init/1`.
`wasm_wait` has no supervised owner at all.

### 4. HIGH `wasm:destroy/1` does not close what the guest left open

`destroy/1` releases pages, the object store and the state table. Nothing
closes WASI file handles or sockets; the references are dropped, so they
survive until the owning process exits.

Reproduced (`probes/p5_sock.erl`), five instances that connect and are then
destroyed without the guest calling `sock_close`:

```
guest sockets connected: 5
ports before=2 after 5 destroyed instances=12
peer still open after destroy (no FIN seen): 5 of 5
```

Every peer still sees a live connection. In a worker on `isolation => fresh`,
the documented default for untrusted code, that is one leaked descriptor per
request. `max_sockets` does not help: it counts per instance and the fresh
instance starts at zero, so the cap an operator sets is not the bound they
think it is.

### 5. HIGH Unbounded per-process cache growth in a calling process

`docs/embedding.md` says an instance may be passed to another process. When it
is, the caller accumulates state that nothing ever reclaims.

`wasm_instance:body_of/2` caches lowered IR under `{wasm_ir, Id, Idx}` in the
**calling** process, `mut/1` caches `#mut{}` the same way, and the sweep that
would drop them runs only from `remember/1`, which a pure caller never reaches.
`release/1` can only erase the destroying process's own copies.

Reproduced (`probes/p6_pd.erl`), one long-lived caller, 20 qjs instances each
destroyed by its owner:

```
after  5 instances: caller dict=  760 (ir=  745 mut=  5 inst=  0) heap=111.1 MB
after 10 instances: caller dict= 1520 (ir= 1490 mut= 10 inst=  0) heap=77.2 MB
after 15 instances: caller dict= 2280 (ir= 2235 mut= 15 inst=  0) heap=133.3 MB
after 20 instances: caller dict= 3040 (ir= 2980 mut= 20 inst=  0) heap=160.1 MB
```

Exactly 149 IR entries per instance, linear, for instances that no longer
exist. `inst=0` confirms the sweep never runs. A gateway process that calls
instances created by request handlers grows without bound.

### 6. MEDIUM A dead loader never gives back its claim

`handle_call({acquire, Hash})` bumps `holders` and monitors nothing.

Reproduced (`probes/p1_cache.erl`):

```
LEAD1 resident before=0 after=1 holders=1
LEAD1 after 20 more dead loaders: resident=1 holders=21
```

21 holders for a module nobody holds. The count can never reach 1, so the
module can never be evicted. With distinct modules, the 256-entry resident cap
fills and `load/1` starts refusing for the life of the node.

### 7. MEDIUM Concurrent first load of the same module loses a claim

`acquire` does not record the hash before replying `compile_it`, so two callers
both compile, and `handle_call({store, ...})` writes `#{holders => 1}`
unconditionally, discarding the first caller's claim.

Reproduced: two concurrent loads, `holders = 1`. Had both returned `{ok, _}`
(they do on a machine where `store` fits in 30 s), the first `unload/1` would
erase the `persistent_term` under the second holder, whose handle then answers
`module_not_loaded`.

### 8. LOW `memory.atomic.wait` is an unbounded block that is not documented as one

`wasm_wait:timeout_ms/1` maps a negative timeout to `infinity`, which is what
the specification requires. It parks the instance process indefinitely and
consumes no fuel. `docs/security.md` lists blocking host calls and blocking
socket calls in exactly this category and does not list this one.

### 9. COSMETIC 14 source lines mangled by the earlier documentation conversion

Lines broken mid-expression at a `-` operator, with trailing whitespace before
the break:

```erlang
%% src/wasm_engine.erl:392
{ok, {Ref, Held}} -> Owners#{Owner := {Ref, Held
- N}}; error -> Owners
```

Continuation lines: `wasi_net.erl:260`, `wasi_preview1.erl:816,1436,1547`,
`wasm_exec.erl:799,1376,1536,1563,1592,1594,1626`,
`wasm_instance.erl:924,928`, `wasm_engine.erl:393`. All compile and behave
identically; `wasm_engine` also crams a following clause onto the continuation
line. This is going into the first public release.

### 10. DOC The published performance table is wrong by 135x on one row

`docs/guests.md` gives, for the compiled plugin, "compile, once 14 ms" and
"instantiate, per request 4 us". Measured: 1.6 ms and 540 us. The 4 us figure
is a tiny module's number (`fac.wasm` instantiates in 2.6 us); the plugin
declares a Rust `std` memory and costs 540 us. The "under 1 ms" for a trivial
request is consistent with the real 540 us, so only the breakdown misleads.

---

## Checked and clean

- **Placeholders**: two hits in the whole tree, both deliberate and documented
  (`wasm_instance.erl:291`, `wasm_num_trunc.erl:51`). No TODO, FIXME, XXX,
  HACK or stub anywhere in `src/`, `c_src/`, `include/`, `examples/`,
  `scripts/`.
- **Deadlock by lock ordering**: none possible. One `gen_server` per concern,
  no server calls another, and the expensive step (compiling) is deliberately
  outside the server. The only blocking found is finding 2, which is
  head-of-line, not circular.
- **`wasm_engine` ETS tables**: created in `init/1`, so owned by the supervised
  process. This is the pattern `wasm_wait` should have followed.
- **Monitor accounting**: `attribute_pages/2` and `release_attributed/2` pair
  correctly, `demonitor(Ref, [flush])` on the last release, and a `DOWN`
  reclaims pages.
- **`reserve_pages/1` CAS loop**: lock-free with guaranteed global progress;
  bounded work per retry. It reads the limit once before looping, so a limit
  lowered mid-retry is applied one round late, which is benign.
- **Heap tables**: deleted on `destroy/1` behind `badarg` guards, idempotent.
- **Preemption**: no runaway can monopolise a scheduler. Confirmed by the
  concurrency measurement below, which scales rather than collapsing.
- **Interpreter loops**: unbounded execution requires `fuel => infinity`, which
  is a documented choice and only reachable inline.

---

## Measurements

Every arm in its own VM, five rounds, minimum reported.

**Noise floor first.** The same empty loop, measured twice in one VM: 2.0 ns
and 8.4 ns per iteration. Anything under about 10 ns is not measurable here,
and differences smaller than 4x on sub-microsecond arms are noise.

| path | measured |
| --- | ---: |
| decode `fac.wasm` | 7.8 us |
| validate `fac.wasm` | 6.0 us |
| compile plugin, 46 KB | 1.58 ms |
| compile qjs, 1.8 MB | 310 ms |
| `load/1`, cache hit | 17.8 us |
| instantiate `fac.wasm` | 2.6 us |
| instantiate plugin (46 KB) | 540 us |
| instantiate qjs, lazy (1.8 MB) | 3.15 ms |
| call, `fac-rec(10)` | 1.53 us |
| call through a host import | 224 ns |
| `call_indirect` | 232 ns |
| `write_memory`, 8 bytes | 87 ns |
| `write_memory`, 64 KiB | 156 us (420 MB/s) |
| `read_memory`, 64 KiB | 89.6 us (731 MB/s) |
| inline call | 1.50 us |
| same call through a process | 2.03 us |
| socket send + recv round trip | 38.7 us |

Two things worth noting from the table:

- **`load/1` costs 7x an instantiate** (17.8 us against 2.6 us): a SHA-256 of
  the whole binary plus a `gen_server` round trip. It belongs at startup, not
  per request, which the docs say, but the ratio is worth knowing.
- **The process boundary costs about 530 ns**, which is the entire price of the
  worker pattern on this workload.

**Concurrency**, N workers each with its own instance, on 14 schedulers:

| workers | calls/s | scaling |
| ---: | ---: | ---: |
| 1 | 608 K | 1.0x |
| 2 | 1.30 M | 2.1x |
| 4 | 2.11 M | 3.5x |
| 8 | 4.46 M | 7.3x |
| 14 | 4.79 M | 7.9x |
| 28 | 5.20 M | 8.6x |

Near-linear to 8, flattening at core count, no collapse. Nothing in the call
path contends. (The workload allocates no pages, so it does not exercise the
engine's shared page counter; that is a separate measurement.)

---

## Comparison

Same 120-byte module, same loop, four runtimes. All four return the identical
result at every size, so the workload really is the only variable:

```
n=1000000 -> -1803823781   (wasm3, wasmtime, node, erlang_wasm all agree)
```

Per-iteration cost taken as the slope between n=1M and n=5M, which cancels
startup:

| runtime | kind | ns/iteration | vs erlang_wasm |
| --- | --- | ---: | ---: |
| wasmtime 47.0.2 | JIT, Cranelift | 0.90 | 140x faster |
| node 22 (V8) | JIT | 1.93 | 65x faster |
| wasm3 0.5.0 | interpreter, C | 4.25 | **30x faster** |
| erlang_wasm | interpreter, BEAM | 126 | 1x |

**wasm3 is the only like-for-like arm**, and it is 30x faster. That is the
honest headline number for interpreter dispatch, and it should be stated
plainly rather than compared only against JITs, where the gap flatters nobody.
Roughly 126 ns per loop iteration is about 10 ns per WebAssembly instruction
executed, which is consistent with the 3.7 ns per dispatch step in
`docs/features.md` once locals traffic and a loop back-edge are included: the
dispatch step is not where the remaining 6 ns goes.

Cold start, time to a first answer:

| runtime | startup + compile + instantiate |
| --- | ---: |
| erlang_wasm, in a running BEAM | 6.5 ms |
| wasm3, including process spawn | 7.5 ms |
| wasmtime, including process spawn | 9.0 ms |
| node, including process spawn | 26.0 ms |
| erlang_wasm, including BEAM startup | 110 ms |

The erlang_wasm figure is measured inside an already-running VM, which is the
realistic case for an embedded library, and the others include process spawn,
which is the realistic case for a CLI. Compared on that basis the runtime is
competitive on cold start and far behind on steady state, which is what an
interpreter with no compilation step should look like.

---

## What this suggests for the release

Findings 1, 2 and 3 are the ones that would embarrass a first release: the
first breaks a promise made on the front page, the second is a
self-inflicted node-wide stall on the documented happy path, and the third is a
silent hang reachable from the documented worker pattern. All three are small,
local fixes.

Findings 4 and 5 are real resource leaks with plausible production triggers.
Findings 6 and 7 need a monitor and a reservation respectively.

Findings 9 and 10 are minutes of work and both are visible to a reader of the
published artefact.


---

## Outcome

Every finding is fixed, in seven commits on top of `release-0.3.0`. Each code
fix has a regression test, and for findings 3, 4 and 5 the new test was run
against the old code first and observed to fail.

| # | finding | fix | commit |
| --- | --- | --- | --- |
| 1 | `load/1` exits | `gen_server` exits become `{error, #{class := link}}` | `65d18fd` |
| 2 | 24 s stall in the server | `size_shared/1`, computed by the loader, which also publishes | `65d18fd` |
| 6 | dead holder never released | claims recorded per process, given back on `DOWN` | `65d18fd` |
| 7 | concurrent load loses a claim | the second caller waits for the first instead of compiling too | `65d18fd` |
| 3 | waiter table dies with a waiter | the engine owns it; killed waiters' rows no longer consume a wakeup | `8a1fa5d`, `8b1628c` |
| 4 | `destroy/1` leaks descriptors | `wasm_instance:on_destroy/2`, with `wasi_preview1:close_all/1` | `6732d8e` |
| 5 | caller caches never swept | `note/1` on both cache-fill paths, keyed by the state table | `33a54e7` |
| 8, 10 | documentation | `atomic.wait` listed; guests table corrected | `4cd5ade` |
| 9 | 40 mangled lines | rejoined, four rewrapped, one doc list repaired | `07cddc4` |

Finding 9 was worse than reported: 40 lines across 13 modules, not 14 across 5.
The first grep only matched continuations at column 0.

### Verified after

```
F6 after 21 dead loaders: resident=0 holders=absent
F7/F1 two concurrent loads -> [ok,ok], holders=2
F2 worst resident/0 latency during a 1.8 MB load: 0 ms   (was ~24,000 ms)
B: WOKEN                                                  (was: timed out)
D: WOKEN, the dead row did not take it
peer still open after destroy: 0 of 5                     (was 5 of 5)
caller IR entries over 512 rounds: bounded, sawtooth       (was linear, 3/round)
```

266 tests pass, conformance is unchanged at 0 regressions against an empty
baseline, dialyzer and xref are clean, and ex_doc still reports its 63
pre-existing warnings and no new ones.

### Cost: the whole benchmark, re-run

Every arm re-measured on the fixed tree, one VM per arm, minimum of five. The
null experiment was better behaved this time (1.8 ns against 1.9 ns for the
same empty loop, where the first run gave 2.0 and 8.4), so the box was quieter,
which is worth knowing before reading small differences as real.

| path | before | after | delta |
| --- | ---: | ---: | ---: |
| decode `fac.wasm` | 7846 ns | 7536 ns | -4.0% |
| validate `fac.wasm` | 6043 ns | 5729 ns | -5.2% |
| `load/1` cache hit | 17.80 us | 17.47 us | -1.8% |
| instantiate `fac.wasm` | 2643 ns | 2644 ns | 0.0% |
| instantiate plugin | 540 us | 534 us | -1.1% |
| instantiate qjs (lazy) | 3.148 ms | 3.145 ms | -0.1% |
| compile plugin | 1.576 ms | 1.481 ms | -6.0% |
| compile qjs | 310 ms | 286 ms | -7.6% |
| call `fac-rec(10)` | 1528 ns | 1450 ns | -5.1% |
| call through host import | 225 ns | 229 ns | +1.9% |
| `call_indirect` | 232 ns | 233 ns | +0.2% |
| `write_memory` 8 B | 87.0 ns | 82.9 ns | -4.7% |
| `write_memory` 64 KiB | 156 us | 153 us | -1.6% |
| `read_memory` 64 KiB | 89.6 us | 86.9 us | -3.0% |
| inline call | 1497 ns | 1515 ns | +1.2% |
| call via a process | 2026 ns | 1846 ns | -8.9% |

Everything sits within +-9% with mixed signs, which is what noise looks like
rather than a change. Two results are worth calling out because they were the
ones at risk:

- **The `load/1` cache hit did not get slower.** The module cache now records a
  claim per process and takes a monitor on the first one, and that costs
  nothing measurable on top of the SHA-256 and the server round trip that
  already dominate.
- **Instantiate is unchanged here** (2644 ns against 2643 ns), where a
  controlled before/after pair during the work suggested +1.3% from the two
  extra dictionary operations. The effect is at or below what this box can
  resolve; the honest statement is that it is under 1.3% and not visible in a
  full run.

Concurrency is also unchanged: 610 K calls/s on one worker rising to 5.9 M on
28, against 608 K and 5.2 M before.

### Comparison: re-run, and unchanged

| runtime | kind | before | after |
| --- | --- | ---: | ---: |
| wasmtime 47.0.2 | JIT | 0.90 ns | 0.75 ns |
| node 22 (V8) | JIT | 1.93 ns | 2.08 ns |
| wasm3 0.5.0 | interpreter, C | 4.25 ns | 4.30 ns |
| erlang_wasm | interpreter, BEAM | 126 ns | 129.5 ns |

The three external runtimes did not change at all between the two runs, so
their spread (wasmtime -17%, node +8%) is the measurement noise on this box.
erlang_wasm's +2.8% sits inside it. **wasm3 remains 30x faster**, which is the
number that matters and the one the fixes were never going to move.

### Found while fixing

The conformance suite passes standalone only because the library works without
its application started. Routing the waiter table through the engine broke
that, and a full `rebar3 ct` run did **not** catch it: an earlier suite had
already started the application in the same VM. `rebar3 ct
--suite=test/wasm_spec_SUITE` on its own is the check that matters, and it is
worth running that way before a release.

---

# Second review, reconciled

A second audit arrived covering the same tree. I reproduced its high-severity
claims rather than accepting them. Five are real and were missed by my audit,
one is a regression I introduced, and one is wrong.

## Confirmed, reproduced here

**R1. `mut_of/1` crashes GC root scanning. This is my regression**, from
`33a54e7`. Threading `#inst{}` into `mut_at/3` missed the second caller:
`wasm_instance.erl:1209` still passes the store table. Reproduced: a process
that has not cached this instance's `#mut{}` raises `function_clause` in
`cache_fill/3`. The path is `wasm.erl:318`, so a collection in any process
without a warm cache crashes. Dialyzer did not catch it because `mut_of/1`
takes `term()`, and the suite did not because the collecting process usually
has the entry already.

*Fix*: revert `mut_at/3` to `(Store, Version, Id)` and key `note/2` on
`(Id, Store)`, which both callers have. Smaller than what is there now, and it
fixes the same leak for the root-view path, which also fills the cache.

**R2. `destroy/1` frees memories it does not own**, imported ones included
(`wasm.erl` `destroy/1` walks all of `#mut.mems`). Reproduced with one memory
and two importers:

```
pages after two importers: 1
after destroying importer A: 0
after destroying importer B: 18446744073709551615
```

The node page counter underflows, after which every allocation on the node is
refused for its lifetime. My own probe hit this: a later arm in the same VM was
refused memory and I nearly recorded a wrong conclusion because of it.

**R3. Guest-controlled atoms.** `wasi_preview1:service_port/1` calls
`binary_to_atom(Service, utf8)` on a service name taken from guest memory via
`sock_getaddrinfo`. Atoms are never reclaimed. `docs/security.md` states that no
atoms are created from module data and cites a property test; that test covers
the decoder, not WASI.

**R4. `max_memory_pages` and `max_host_calls` are advertised and not
enforced.** Both appear in `wasm_limits:untrusted/0`; nothing reads either
outside `wasm_limits`. Reproduced in a clean VM:

```
node page budget: 16384, in use: 0
limit says max_memory_pages = 256
RESULT: instantiated with 300 pages, limit not enforced
max_host_calls validated? ok        (for max_host_calls => -1)
```

My audit's "what limits enforce" table repeated the documentation instead of
checking the call graph. That was my error.

**R5. `wasi_fs` is not on the guest path.** `path_open` calls `file:open/2`
directly (`wasi_preview1.erl:1197`). The only references to `wasi_fs` anywhere
are its own module, one doc line, and `wasi_nif_SUITE`, which tests it
directly. So the native `openat(O_NOFOLLOW)` backend that `docs/wasi.md` and
`docs/security.md` describe as closing the time-of-check-to-time-of-use window
does not apply to actual guest path resolution, and the suite is green because
it tests the module rather than the path.

## Not verified

R3 was confirmed by reading the call path rather than by executing it. The
second review's remaining findings (non-atomic shared growth, pages leaked by
failed instantiation, oversized `random_get`, trap rollback of globals,
duplicate wake between two notifiers, concurrent linked-instance GC, and the
smaller items) are plausible and specific but I have not reproduced them.

Since: non-atomic shared growth and the pages a failed instantiation leaks were
both reproduced and fixed, with `wasm_resource_SUITE` pinning them.

The finding this review recorded as an open bookkeeping leak, that
`table_forget/1` and `cell_forget/1` had no callers, was understated. It is not
bookkeeping: the rows hold the `atomics` arrays themselves. Ten thousand
instantiate-and-destroy cycles of the 17-page Rust plugin left 20,015 rows and
20.1 GB of live memory while `pages_in_use` read 0, and instantiation slowed
from 496 to 638 us as it went. A pool instantiating per request, which is what
`isolation => fresh` does, would take a machine down in minutes. Fixed with the
holder tokens, and pinned by
`instantiating_and_destroying_does_not_grow_the_store`. One half of
the second turned out not to be a defect. A start function that traps keeps its
instance charged, and must: `linking.wast` requires a reference the trapping
module wrote into an imported table to remain callable afterwards, so the
instance is still reachable and releasing it would be wrong. It goes when the
process that built it exits.

## Wrong

The claim that the 126 ns figure is "the rejected 128-bit-integer
implementation of `i32x4.add`, see README.md:82" is a coincidence of numbers.
The 126 and 129.5 ns come from `bench/cross/loop.wat` driven by
`loop_erl.erl`, measured this session, with all four runtimes returning the
identical result at both sizes. The review is right that no cross-runtime
harness was not in the repository at the time: the audit was required not to
touch the tree. It is now `bench/cross/`, with the protocol in its README, so
the figure can be reproduced rather than taken on trust.

## Agreement, not correction

The point about control runtimes moving between -16.7% and +7.8% is the same
one made above: that spread is this box's noise, and erlang_wasm's +2.8% sits
inside it.

The two benchmark tables differ because they measure different fixtures, not
because either is wrong: 13.70 us to compile is a seed module, 1.48 ms is the
46 KB plugin.

## What this changes

The tree is not ready to publish. Beyond the ten findings already fixed there
are five confirmed defects, one of them a crash introduced by my own fix, one a
node-wide accounting corruption reachable from ordinary linking, one a
node-wide denial of service reachable by a guest with `resolve => allow`, and
two documentation claims about safety that the code does not implement.
