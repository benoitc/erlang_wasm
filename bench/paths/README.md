# Pricing one path at a time

Each arm times one path in isolation, so a change can be charged to the thing
that caused it. Use it when you have changed something on a hot path and need a
number rather than an opinion, and to check a change against a threshold that
was written down before the numbers arrived.

## Arms

Every module in this directory, what it measures or is for, and the section
of this page that covers it.

| module | what it measures | section |
| --- | --- | --- |
| `adopt` | whether a one-call guest ever reaches generated code, watched through `wasm_jit:counts/0` | "Does a reactor ever reach the compiled tier" |
| `allocwords` | heap words one process allocated, and its collection time, from its own collection trace; a library for other arms | "Where a compile's memory is spent, and what a ceiling would cost" |
| `barrier_adapter` | test adapter: holds a request after its last guest call so `densitybench workers` can sample live instances | "Comparing memory representations" |
| `benchlib` | shared helpers every arm needs, such as running work in a fresh process | "Comparing memory representations" |
| `callcost` | what a call costs the interpreter, and what it would cost a compiled function | "What a call costs, and what it would cost a compiled function" |
| `capturebench` | what capturing an image costs: `wasm:snapshot/2` alone and a whole worker start | none |
| `copybench` | one `memory.copy` by direction and alignment, its time and reductions, checked against a binary | "What one memory.copy costs" |
| `compileheap` | where a compile's memory is spent, and what a ceiling on it would cost | "Where a compile's memory is spent, and what a ceiling would cost" |
| `compilephases` | what `wasm:compile/1` costs on a real guest, in total, per phase from inside the same call, and at its peak heap | "What decoding and validating cost" |
| `corespike` | feasibility spike: one function compiled to Core Erlang and run | "Compiling one function instead of interpreting it" |
| `coverage` | what share of a real module the compiled tier takes, and what refuses the rest; a diagnostic | "What the generator actually refuses today" |
| `densitybench` | what a live instance costs the node, and how many fit under a page budget | "Restores, density and footprint" |
| `encodebench` | what `wasm:encode/1` costs on a real guest, next to what decoding the same bytes costs | "What encoding costs" |
| `floor` | the benchmark loop written in Erlang against the interpreter: the floor no interpreter beats | none |
| `fusecount` | which fusion rules fire and how many dispatches they remove; a diagnostic | "Which fusion rules actually fire" |
| `fuseoff` | one module's loop timed with `fuse => false` and `fuse => true` | none |
| `gap` | compiled wasm against the same algorithm written in Erlang, per kernel | "How far compiled code is from plain Erlang" |
| `guestarm` | one start-up of a real language runtime, priced on the process that runs it | none |
| `guestprof` | where a real guest's compiled run spends its time, and what memory it touches | "Where a real guest's time goes" |
| `instbench` | what a fresh `wasm:instantiate/3` costs, for each way a module reaches it | "Memory kernels and instantiation" |
| `listbench` | a `list<u32>` round trip through a component, and the memory calls it makes | "What passing a list to a component costs" |
| `lowbench` | a request's wall time on a real guest, and what its first request costs | none |
| `matrix` | the instrument for repeated runs: wall, CPU, reductions, collections and msacc per run; a diagnostic | "The measurement protocol, and why it is not optional" |
| `optbshare` | what K held instances cost the node and the OS, per instance, including memory outside the BEAM's allocators | "Restores, density and footprint" |
| `pagedbench` | the `storebench` and `gap sieve` memory kernels over a plain and a restored memory | "Memory kernels and instantiation" |
| `pathbench` | the path arms: decode, validate, instantiate, call, memory, WASI and more, one at a time | "Run an arm" |
| `perinstr` | per-instruction cost and allocation, from a snippet repeated K against 2K times | none |
| `phasing_adapter` | test adapter: times one worker request at its adapter boundaries | "Where a request's milliseconds go" |
| `pyarms` | the four CPython configurations, each proving which one ran | none |
| `reactorlib` | reactor images and one request against them, without a worker; a library for other arms | "Comparing memory representations" |
| `realbench` | real compiler output rather than the synthetic loop, one process per run; the check for any dispatch change | "Changing the dispatch path: check QuickJS first" |
| `relop` | comparison operators as `wasm_exec` once wrote them against a direct clause | none |
| `reqbench` | requests a second through a pool, and which node-wide processes they queue behind | "Many callers on a pool, and what they queue behind" |
| `requestbench` | one script worker's request latency: a fresh node's first request, and steady ones | "One worker's request latency" |
| `restorebench` | what `wasm:restore/3` and `wasm:load_snapshot/2` take, per guest | "Restores, density and footprint" |
| `restorebits` | what one `wasm:restore/3` spends, and on what | none |
| `retainbench` | what a compiled module holds of its input once the input is gone | none |
| `sockbench` | a WASI socket send and receive round trip against a local TCP echo | none |
| `ssaprofile` | where a cold compile of QuickJS's hot set spends its time: by pass, by `beam_ssa_opt` sub-pass, by generated function | "Where a compile's time is spent" |
| `storebench` | what a store costs in generated code | "What a store costs in generated code" |
| `subset` | how much of a real module a compiler could take, one restriction at a time; a diagnostic | "How much of a module a compiler could take" |
| `teardown` | what it costs to take down a process that was carrying an image | none |
| `tiered` | whether the compiled tier is actually running the program | "Is the tier actually running the program" |
| `watbench` | WAT corpus parse time, result digest and type scaling | "What parsing text costs" |
| `workerbench` | what a worker host sees per request, and when the tier changes it; also heap-floor sweeps | "Pricing a request rather than a path" |

## Run an arm

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/pathbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pathbench main call
```

Start with `null`, which times an empty fun. Two arms that should be identical
and are not tell you what the box is doing to you before any of the rest means
anything.

```sh
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pathbench main null
```

The arms: `null`, `decode`, `validate`, `compile_small`, `compile_big`,
`load_hit`, `inst_small`, `inst_plugin`, `inst_big`, `call`, `call_host`,
`call_indirect`, `br_table`, `memory`, `mem_create`, `grow`, `wasi_write`,
`worker`, `concurrency`.

## Compare against another commit

One arm per VM, several launches, minimum of five rounds. Build the other side
somewhere else rather than rebuilding in place, and interleave the launches so
a change in the box's load lands on both:

```sh
mkdir -p /tmp/base && git archive <commit> | tar -x -C /tmp/base
cp bench/paths/pathbench.erl /tmp/base/bench/paths/
(cd /tmp/base && rebar3 compile && erlc -o bench/paths \
    -pa _build/default/lib/wasm/ebin bench/paths/pathbench.erl)

for i in 1 2 3; do
  (cd /tmp/base && erl -noshell -pa _build/default/lib/wasm/ebin \
      -pa bench/paths -run pathbench main grow)
  erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
      -run pathbench main grow
done
```

## Thresholds, and what they cost

A threshold chosen after seeing the result is not a threshold. Write yours down
before the numbers arrive. The thresholds set for the resource model, execution
leases, keeping what a trap wrote, the invocation budget and the page ceiling,
and what each came out at, are in `test/audit/PERF.md`, section "Path arm
results (from bench/paths/README.md)".

## Which fusion rules actually fire

A rule that never matches and a rule that matches and does not pay look
identical in a timing. `fusecount` tells them apart by walking the lowered IR
of an instance built with `fuse => true` against one built with `fuse =>
false`, so nothing is counted inside a timed run and the interpreter carries no
counters:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/fusecount.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run fusecount main test/fixtures/lang/qjs.wasm
```

Add `show` after the path to print the IR, which is readable for a benchmark
loop and is not for anything else.

What it counted on QuickJS, the Rust plugin and the benchmark loop, and what
`fc183c1` actually did, are in `test/audit/PERF.md`, section "Path arm results
(from bench/paths/README.md)".

## Compiling one function instead of interpreting it

`corespike` answers a feasibility question and no others: what would a
compiler get, if wasm IR were turned into Core Erlang and handed to the
compiler and JIT that are already here?

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/corespike.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths -pa bench/cross \
    -run corespike main bench/cross/loop.wasm
```

It asserts the same checksum as the interpreter at five sizes before it reports
a time, because a faster answer to a different computation is not a result.
What it measured is in `test/audit/PERF.md`, section "Path arm results (from
bench/paths/README.md)".

It is in `bench/` and not `src/` on purpose. It loads one literal module name,
once, never unloads or purges, and covers only blocks, loops and the i32
arithmetic this loop uses; anything else raises `{unsupported, Instr}`. See
`test/audit/PERF.md` for the list of what a real compiler would have to handle
first.

## How much of a module a compiler could take

`corespike` reports 2.59 ns/iteration on a subset. `subset` says how much of a
real module has that shape, by walking the lowered IR of every function and
sorting each instruction into a category. A compiler supporting a set of
categories can take exactly the functions whose categories fit inside it, so
the table is a direct answer to "what does the next restriction buy".

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/subset.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run subset main test/fixtures/lang/qjs.wasm why
```

The table it produced for QuickJS and the Rust plugin, and what it means for a
compiler, are in `test/audit/PERF.md`, section "Path arm results (from
bench/paths/README.md)". Static counts weight every instruction equally, so
read the table as a ceiling on coverage, not as a share of run time.

## The measurement protocol, and why it is not optional

Read this before taking any number from this directory. **Run one process per
run:** repeating QuickJS in one process is bimodal, about 1.7 s or about 13,
and a fresh process per run takes the spread to 1.02x. **A minimum only means
something across runs from one distribution:** the 1.33x once reported for
the compiled tier was a minimum landing on a fast run for one arm and a slow
one for the other. `matrix.erl` is the instrument for this class of question
(workloads `qjs`, `plugin`, `memloop`, `arith`; modes `same`, `fresh`,
`helper`), and `msacc` says in one run whether lost time went to collection,
the emulator, a port or NIF, or auxiliary work: reach for it before
theorising.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/matrix.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run matrix main qjs same 5
```

The full protocol, from writing the gates down first to recording the result,
is in `docs/contributing/measuring.md`.

## Is the tier actually running the program

`tiered.erl` counts the interpreter's own dispatch, tier off and tier on, by
call-count tracing `wasm_exec:run/3`.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/tiered.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run tiered main qjs
```

**This is the gate on any change that adds instructions to the subset, and
coverage is not.** The share of *functions* that compile has pointed the wrong
way twice: QuickJS reached 93% compiled while about 1% of its executed
instructions were, because one unsupported instruction anywhere in the hot
function keeps that whole function interpreted, and a bytecode interpreter is
one function.

Counting function *entries* is no better and is how the mistake was actually
made: with the tier on, QuickJS entered 204 functions interpreted against
23,069, and each of those 204 ran a loop of about 720,000 instructions. A
function entered once and a function entered once that runs for a second are
indistinguishable by call count.

The wall times it prints are not a speedup: tracing charges the arm that
dispatches 148 million times and charges nothing to the arm that dispatches
none. Take speed from `realbench`.

## What the generator actually refuses today

`subset` answers what a compiler *could* take. `coverage` answers what this one
does, by asking `wasm_core:can_compile/2` about every function, so it reports
the decision the tier will make at run time rather than a model of it.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/coverage.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run coverage main test/fixtures/lang/qjs.wasm
```

Run it before and after every change that adds an instruction to
`wasm_core:supported/1`, and put both histograms in `test/audit/PERF.md`. A
change that adds an instruction and does not move coverage has not paid for
itself.

Refusals are tallied by the *first* refusing instruction in each function, which
makes the histogram an ordering and not a census: removing the top entry
uncovers whatever stood behind it. Predicting the next coverage number by
summing rows overshoots, and has, by 7 points.

Today: 100% of the Rust plugin and 83% of QuickJS, whose remainder is floats and
SIMD.

## What a call costs, and what it would cost a compiled function

`subset` says the boundary is the first thing a back end needs. `callcost`
prices it, before any of it is written:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/callcost.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths -pa bench/cross \
    -run callcost main
```

What it measured, and the limits it gives a code generator, are in
`test/audit/PERF.md`, section "Path arm results (from bench/paths/README.md)".

## Changing the dispatch path: check QuickJS first

Three separate changes to `run/3`, `branch/3` or what they call have now cost
about 70% on real compiler output while measuring nothing, or an improvement, on
`bench/cross/loop.wat`. The most recent was replacing `lists:nth/2` plus
`lists:nthtail/2` in `branch/3` with a single traversal, which is strictly less
list work and cost QuickJS 75%.

So run `realbench` before believing anything else:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/realbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run realbench main qjs
```

Interleave it against the previous commit, five pairs, and compare minimums.
The loop cannot see this class of regression, and neither can any of the call
arms.

## Where a compile's memory is spent, and what a ceiling would cost

`PERF.md` records that a `max_heap_size` ceiling on the process `wasm_jit`
spawns sees 0.34 GB of a compile whose node reaches 6.19 GB, because
`compile:forms/2` runs its passes in a process of its own, and that moving the
work onto that same long-lived coordinator with `no_spawn_compiler_process`
costs 75% more compile time. `compileheap` asks the question that experiment did
not: what does the same option cost in a *fresh, disposable* process of our own,
which is the lifecycle OTP's own child already has?

```sh
erlc -I _build/default/lib -o bench/paths bench/paths/compileheap.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main test/fixtures/lang/qjs.wasm 5
```

Prove the instrument first. It groups collection events by pid, which
`allocwords` does not and cannot, since its estimator pairs a start with the end
after it and that is sound only within one process:

```sh
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main validate
```

Three arms compile the same `Core`, built once before any of them: `otp` as
`wasm_core:module/9` calls it today, `inline` with
`no_spawn_compiler_process` on the measuring process, and `child` with the same
option in a fresh process under the `max_heap_size` map that would ship. The
gate is one ordered rule on `R = child min / otp min`, from the **clean,
untraced** walls: `R =< 1.10` ships, `1.10 < R =< 1.20` ships opt-in, `R > 1.20`
stops.

Four things it will not let you get wrong, each of which cost a draft:

- **The wall it gates on is untraced.** The arms differ in how many processes
  exist and so in how many collection events the instrument sees, which is the
  same trap `pyarms` records as "the traced wall is not the wall".
- **`[procs, set_on_spawn]` delivers zero collection events.** A child inherits
  only the flags its parent carries, so the trace needs
  `[procs, garbage_collection, set_on_spawn, monotonic_timestamp]`, and that
  last flag makes every message a `trace_ts` tuple with a timestamp appended.
  A harness matching `{trace, ...}` matches nothing and silently finds no child.
- **The `otp` arm's allocation is a floor, printed with a `>`.** Its compiler is
  spawned inside `compile:do_compile/2` and exits with its result, so no closing
  collection can be forced and the final live set is unmeasured.
- **The sampled peak is a lower bound**, always: a peak between two 50 ms
  samples is invisible, and so is the memory the collector needs while
  collecting. Never size a ceiling by it.

## Where a compile's time is spent

`ssaprofile` answers which passes, which `beam_ssa_opt` sub-passes and which
generated functions a cold compile spends its time on. Use it before changing
the generator to make compiling cheaper: the result is in `PERF.md`, "Where
the compiler's time goes on QuickJS's hot set".

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/ssaprofile.erl
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run ssaprofile main capture /tmp/qjs.core
erl -noshell -pa bench/paths -run ssaprofile main passes /tmp/qjs.core
erl -noshell -pa bench/paths -run ssaprofile main perfun /tmp/qjs.core /tmp/perfun.terms
```

- `capture` saves the Core the background compiler hands to
  `compile:forms/2` for the `realbench qjs on` script, so every later step
  compiles the same input. It needs the dependencies on the path, hence
  `ERL_LIBS`; the other steps need only OTP.
- `passes` compiles it with the documented `time` option, which prints every
  pass and every `beam_ssa_opt` sub-pass.
- `tprof` ranks the compiler's own functions inside one compile.
- `perfun` compiles each generated function alone and writes one
  `{Name, Arity, Microseconds, CoreNodes}` term per function; `subpass` sums
  the `time` output of those compiles, to set beside `passes`.
- `shape` counts the BEAM functions, arities and instructions the unit
  becomes. `brtable` measures the share of Core the `br_table` arms are.

In `perfun`, every other function is a stub that answers `erlang:get/1`, and
the function under test is exported. A stub that cannot return lets the type
pass delete everything after each call, and an unexported function nobody
calls is removed before any SSA pass runs; the first draft of this arm made
both mistakes, and the arm now asserts the function is in the compiled
module.

## What decoding and validating cost

`compilephases` times `wasm:compile/1` on a real guest, in total and phase by
phase, and records its peak heap and what each phase allocates. Use it for a
change to `wasm_decode` or `wasm_validate`; its results are in `PERF.md`,
"One-byte immediates in the decoder loop, timed through `wasm:compile/1`".

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/compilephases.erl
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run compilephases main time qjs 5
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run compilephases main peak qjs
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run compilephases main alloc python
```

- `time GUEST ROUNDS` makes one complete `wasm:compile/1` call per round in
  a fresh process, so the heap floor it sets for a module over 16 KiB is part
  of what is timed. Decode and validation come from call and return
  timestamps inside that same call, and the launch prints the round with the
  lowest total with its own phases, plus the 5-minute load average at the
  start and the end.
- `peak GUEST` prints the largest heap, young plus old, the compiling process
  held at any collection during one call.
- `alloc GUEST` prints the words each phase allocates when called directly.
  Only a wrapper around the phase is traced: `wasm_validate:module/1`
  tail-calls its worker, so tracing it directly charges nothing, and tracing
  a helper moves that helper's words out of the count.
- Timing the phases by calling them directly skips that heap floor and gives
  a different answer: it reported a validation slowdown the public call does
  not have, and a validation speed-up it mostly does not have either.
- A driver that waits for low load must wait on the same average the arm
  records. Waiting on the 1-minute average while checking the 5-minute one
  discarded every short QuickJS run of one set.

## What passing a list to a component costs

`listbench` times a round trip of a `list<u32>` through the vectors
fixture's `echo-list-u32` export and counts the memory calls it makes. Use it
for a change to how `wasm_canon` lifts or lowers lists; its result is in
`PERF.md`, "A list of u32 across guest memory a block at a time".

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/listbench.erl
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run listbench main time 4096 5
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run listbench main count 4096
```

- `time N ROUNDS` makes one round trip per round in a fresh process, checks
  the answer, and prints the lowest of the rounds with the 5-minute load
  average at both ends.
- `count N` counts `wasm:read_memory/3` and `wasm:write_memory/3` calls in one
  round trip, the eight-byte read of the result's pointer and length apart.

## What one memory.copy costs

`copybench` times one `wasm_memory:copy/4` of a given shape and counts its
reductions, checking the result against the same copy made on a binary. Use
it for a change to how memory is copied; its result is in `PERF.md`,
"memory.copy by words when it overlaps or is aligned differently".

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/copybench.erl
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run copybench main 8 0 65536 5
```

The arguments are the destination, the source, the length and the rounds.
`8 0 65536` overlaps from above with the two aligned alike, `65537 0 65536`
is aligned differently and clear of the source, `9 0 65536` is both, and
`65536 0 65536` is the aligned forward copy the others are compared with.

## What encoding costs

`encodebench` times `wasm:encode/1` on a module `wasm:compile/1` gave, the
encoder alone on the decoded record, and `wasm_decode:module/1` on the same
bytes, each round in a fresh process. Use it for a change to `wasm_encode` or
the opcode-space encoders; its result is in `PERF.md`, "Encoding a module".

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/encodebench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run encodebench main test/fixtures/lang/qjs.wasm 5 decode_first
```

- The arguments are the module, the rounds, and which is timed first in each
  round, `decode_first` or `encode_first`. Run both, each in a fresh
  emulator, alternately.
- It prints the lowest time of each, in microseconds, the size of the encoded
  bytes and the 5-minute load average at both ends.
- It checks first that the compiled and the decoded record encode to the same
  bytes, so the two encode timings describe the same output.

## What parsing text costs

`watbench` times `wasm_wat:module/1` over every text module in the
specification suites and checks what it returns. Use it for a change to
`wasm_wat`; its result is in `PERF.md`, "WAT parsing with many type
declarations". Fetch the suites first (`make suites`), and build the test
profile so the suite's own inputs are on the path:

```sh
rebar3 as test compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/watbench.erl
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -pa _build/test/lib/wasm/test -run watbench main corpus 5
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -pa _build/test/lib/wasm/test -run watbench main digest
ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \
    -run watbench main scale 8000
```

- `corpus ROUNDS` parses every input once per round in a fresh process and
  prints the lowest total, with the 5-minute load average at both ends.
- `digest` parses each input once and prints how many parsed and a SHA-256
  over all the results, so you can check two revisions answer the same.
- `scale N` prints the reductions per type of a module of `N` type
  declarations.
- The inputs are the text modules of the `.wast` files (2,144 at the last
  count) and, when `wasm_wat_SUITE` is on the path, its own 96 sources.
  Without `-pa _build/test/lib/wasm/test` the count drops to 2,144 and
  nothing says so but the `modules` field: compare it on both sides.

## Short notes

- The box matters more than most of these differences. Taken here at load
  average 12 to 14; the same box at 30 moved control arms by 17% between runs.
- `grow` deliberately runs 200 growths and not 3000. Each one appends a chunk
  and rebuilds the chunk tuple, so a long run measures the O(n) rebuild rather
  than the round trip the arm exists to price.
- Take a per-iteration cost as the slope between two sizes where you can. A
  single arm's absolute number includes whatever setup the fun does.

## Pricing a request rather than a path

`workerbench` is the one arm here that does not time a path inside the runtime.
It times what a host sees: a request arriving at a `wasm_script_worker`, an instance
made for it, and the latency changing underneath when generated code lands.

```sh
erlc -o bench/paths -pa _build/test/lib/wasm/ebin \
     -pa _build/test/lib/wasm/examples bench/paths/workerbench.erl
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main qjs compiled warm 500 \
        "$PWD/_build/bench-cache"
```

**Not `/tmp`.** The cache validates its directory now, and `/tmp` fails twice
over: it is a symlink to `private/tmp` on macOS, and `/private/tmp` is
`drwxrwxrwt`. A run pointed there gets no cache at all and says so once in the
log -- which, before this was written down, is exactly the shape of a warm arm
that quietly measures a cold one. Use an absolute path you own with no group or
other write bit; `_build` is gitignored and convenient.

Three cache arms, and the third is the one that matters:

| arm | `code_cache_dir` | what it answers |
| --- | --- | --- |
| `adoption` | unset | does request *n* adopt what *n-1* compiled, with no disk involved? |
| `cold` | an empty directory | what a first-ever start costs |
| `warm` | that directory, after a cold run | what a restart costs |

`adoption` sets **no** directory rather than an empty one, so the disk cache
cannot be credited for same-node adoption. Tell `warm` apart by
`wasm_jit:counts/0` saying `cached => 1`, not by a wall time: the first two
arms are indistinguishable by latency and differ only in what they prove.

Run the null arm first here as everywhere else. It came out at 16% on the
minimum for a 60-request QuickJS arm, and a CPython arm varies by a third
within itself, which is the difference between a measurement worth printing and
one that is not.

### Sweeping a heap floor

The same module's `floors` mode answers a different question: what
`runner_min_heap_words` is worth on a guest. It is the shape to copy for any
per-worker setting, because it makes the comparison self-controlling.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main floors qjs_reactor metered 10 0 100000 200000
```

One worker per floor, all in **one** emulator, round robin with the order
reversed on alternate rounds, and each request traced for `garbage_collection`
on the processes it creates. Two rules it exists to enforce:

- **Put the off setting in the sweep.** Without a zero arm there is nothing in
  the run to say the setting did anything at all. A CPython sweep without one
  came back flat and had to be thrown away; `ATTEMPTS.md` has it.
- **Never compare across runs.** The floors are compared against each other
  under whatever load the box has, which is the only comparison this machine
  supports.

### Does a reactor ever reach the compiled tier

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main tier qjs_reactor 3000 200000
```

A metered and a compiled worker over the same reactor artifact, alternating in
one emulator, with the heap floor on in both halves. The floor is not optional:
the tier's 8.4x was measured against an unfloored interpreter, and measuring it
against one again would credit the tier with what the floor already does.

**Read `wasm_jit:counts/0`, never the wall time.** An arm where the tier is off
and an arm where it is on and slow are the same number of milliseconds; only
`entered` tells them apart. That is `adopt.erl`'s rule for the command path.

**And give it wall-clock time, not a request count.** The tier arrives after a
fixed amount of compiling, and a reactor request is ten times faster than a
command one, so the same request count buys a tenth of the time the compiler
needs: 3000 requests here is not the 76 s that 353 requests is on the command
path. The mode waits on a deadline, driving requests while it waits, because
the tier advances when calls happen and not when time passes. `ATTEMPTS.md`
records the run that read a slow compile as no compile at all.

The `floors` and `throughput` modes take the config as an argument too, so
either can be run `compiled` rather than `metered`.

### Measuring from a node that has arrived

`steady` is the mode for questions about a node in its final state rather than
on its way there: module compiled, compiler gone, counters zeroed. It has three
arms, because three gates need different setups.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main steady qjs_reactor latency 200 200000
```

- **latency**: one compiled and one metered worker, alternating. Answers the
  compiled median against the metered median in the same emulator.
- **throughput**: compiled workers at 1, 2, 4, 8 and 14, with a metered control
  at each count. **Normalise before comparing revisions.** The metered control
  ranged from 182 to 331 req/s across five runs of the same thing, so a raw
  rate comparison is mostly box.
- **control**: the tier on so every call pays the residency lookup, and a
  `compile_after` above every call the arm makes so no compile ever starts. It
  prices one thing. Its end state is the *opposite* of the other two and is
  asserted separately: nothing resident, counts zero.

**Wait for quiescence, do not infer it from residency.** `publish/1` makes a
slot resident before the compiler bumps `compiled` and takes its own lease, so
a harness that resets counters the moment residency appears races all three.
`steady` waits for the target's lease count to reach zero and the compiler
children to go, then reads and asserts a non-zero compiled count before
resetting. Without that assertion a comparison can read 0 on both sides and
agree vacuously.

**Find the target by hash, not by key.** The JIT's slot key is
`{identity, ?ABI}` and `?ABI` is private to `wasm_jit`, so a benchmark that
spelled it would go stale at the next ABI bump. `wasm_code_slots:resident/0`
answers `{Name, Key, LeaseCount}`; match the artifact's own hash inside `Key`.

To compare revisions, copy this file into the older tree and compile it there,
as the cross-commit protocol above does with `pathbench.erl` -- the older tree
does not contain this mode. The reactor `.wasm` fixtures are built rather than
committed, so copy those across too or the older arm cannot start.

### What a cold node pays, and whether a cache spares it

`coldnode` measures the window before the tier is running, which for a reactor
nothing had measured.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main coldnode lua_reactor "$PWD/_build/c1" cold serve w
```

The arguments are the guest, an **absolute trusted** cache directory, `cold` or
`warm`, `serve` or `wait`, and `w` or `b`.

Four things it does that are not optional, each because getting one wrong
produces a plausible number:

- **The snapshot is prepared outside the timed arm, and the arm checks it was
  loaded.** Setting `snapshot_dir` proves nothing: a worker that finds no image
  captures instead, silently. The first CPython run here exited with
  `{worker_captured_rather_than_loaded, 108990, 20000}` rather than quietly
  reporting a hundred and nine seconds of somebody else's work.
- **The clock starts after the worker is up**, so the snapshot is reported
  apart from the compile rather than inside it.
- **The number of shards is recorded.** `cached/6` skips the lookup entirely
  for a sharded compile, so a sharded arm reports `cached = 0` for a reason
  that has nothing to do with the cache.
- **The slot is recorded**, because it is in the cache key: two arms in
  different slots miss each other whatever else matches.

To ask whether a *different* script hits a warm cache, use **two emulators over
two clones** of the same seeded directory -- one running `w`, one running `b`.
One emulator cannot answer it: whichever runs first becomes resident and the
second adopts its code without ever consulting the cache.

### Scaling, where interleaving does not save you

The `throughput` mode sweeps worker counts and reports requests per second,
with and without a heap floor, sampling peak process memory as it goes.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main throughput qjs_reactor metered 25 200000 1 2 4 8 14
```

**This is the one arm here that cannot be made self-controlling.** A latency
sweep interleaves its arms and is readable against whatever else the box is
doing. A scaling curve needs idle cores and no trick substitutes for them: run
it on a busy box and you measure the box. So the mode prints `top`'s idle
percentage as well as the load average, at both ends, because a one-minute
load average decays for fifteen minutes after the previous arm and says nothing
about now.

What survives a busy box is the *comparison* between two arms of the same
count, since both met the same machine in the same minute. What does not is the
absolute ceiling: read a flattening curve as this machine's free cores until
you have run it somewhere quiet.

One trap in the memory column. A floored arm finishes sooner, so it is sampled
fewer times and its peak is the worse estimate of the two. That bias runs
against the floor, so a *lower* floored number is safe to believe and a higher
one is not; when it mattered, `PERF.md` re-ran the two arms with request counts
chosen to make them the same length.

### Comparing two revisions of the kernel

`floors` and `steady` control for the box inside one run, and a number from
one run must never be compared with a number from another. When the question
is "did this change make the worker slower", both revisions have to run in the
same emulator, and `revision` does that: the old kernel is compiled twice from
the other tree with every module renamed, `o1_` and `o2_`, and loaded beside
the new one. Each side gets its own worker, reaper and scratch root. The
`null` arm runs o1 against o2, so it has exactly the topology of the `ab` arm,
which runs o1 against the new kernel.

Build the two copies from the tree to compare against:

```sh
git worktree add ../base main
for P in o1 o2; do
  mkdir -p ../$P
  for M in script_worker worker_reaper script_v1 worker_error \
           qjs_reactor_adapter lua_reactor_adapter py_reactor_adapter; do
    perl -pe 's/\b(script_worker|worker_reaper|script_v1|worker_error|qjs_reactor_adapter|lua_reactor_adapter|py_reactor_adapter)\b(?=[:),. \]\n]|$)/'"$P"'_$1/g' \
      ../base/examples/$M.erl > ../$P/${P}_$M.erl
  done
  (cd ../$P && erlc -pa ../erlang_wasm/_build/test/lib/wasm/ebin -pa . *.erl)
done
```

The rename leaves `(` out on purpose: `worker_error()` is also a type, and
renaming it breaks the module. Then run a whole acceptance set:

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/test \
    -pa ../o1 -pa ../o2 -pa bench/paths \
    -run workerbench main revision_set qjs_reactor latency 200 200000
```

`revision_set` runs every run in a fresh emulator: pairs in two orderings,
F (null then ab, o1 first) and R (ab then null, the other side first),
alternating, three pairs of each for `latency` and six for `throughput`. The
gate is the one `phases` uses, applied per ordering: the median of the paired
ratios inside [0.95, 1.05] and no bimodal set, with bimodality taken on raw
times or raw counts. The null must pass first, or the set is discarded and
run again, up to three times; a throughput run under 50% idle at either end is
run again. It prints both orderings' results and a pooled figure that gates
nothing, and exits non-zero on a failure. `revision null F qjs_reactor
latency 200 200000` runs a single run, for debugging.

Seen to fail: a new kernel slowed by 3 ms a request fails both orderings at
about 1.19.

### Where a request's milliseconds go

`phases` decomposes one request at the five adapter boundaries, using the real
worker rather than a reconstruction of it: `bench/paths/phasing_adapter.erl`
wraps the real adapter and timestamps both sides of every callback.

```sh
erlc -Werror -o bench/paths -pa _build/test/lib/wasm/ebin \
     -pa _build/test/lib/wasm/test/support \
     bench/paths/phasing_adapter.erl bench/paths/workerbench.erl

erl_paths=(-pa _build/test/lib/wasm/ebin
           -pa _build/test/lib/wasm/test/support -pa bench/paths)

erl -noshell "${erl_paths[@]}" -run workerbench main phases smoke
erl -noshell "${erl_paths[@]}" -run workerbench main phases seed  py_reactor
erl -noshell "${erl_paths[@]}" -run workerbench main phases null  py_reactor compiled
erl -noshell "${erl_paths[@]}" -run workerbench main phases pairs py_reactor \
    interpreted compiled
```

An array, not a scalar: zsh does not word-split an unquoted `$P`, so a single
`-pa a -pa b` string reaches `erl` as one argument and the module is "not
found". That cost a run here.

Order matters, and `set -e` is part of the procedure. `smoke` and `calibrate`
gate the instrument; `seed` fills the cache and the image directory and writes
the manifests; `null` runs before `overhead` and both before `pairs`, because a
failed null invalidates every timing run after it. An arm that fails a gate
writes its record and halts the emulator non-zero.

**Re-seed after any harness change.** Every arm asserts a code manifest -- the
runtime, kernel, adapter and harness BEAMs by content, plus HEAD and a diff
hash -- against what the seed recorded, because these runs happen from a
worktree that is still being edited and a git SHA names the parent commit
rather than the code that was loaded. It caught a recompile between a seed and
its arm on the first day it existed.

Three rules this mode adds to the protocol above:

- **The window is silent.** Validation, phase assembly, gate arithmetic,
  counter reads and printing all wait until the twelve samples are done.
  Printing per sample puts a gap between requests and changes the cleanup
  overlap the controls are there to measure.
- **The residual is an assertion.** The intervals are contiguous, so they sum
  to the total identically; a non-zero residual is an assembly bug and fails
  the sample. It is never reported as an unexplained cost.
- **Small phases need the overhead arm.** `overhead` prices the wrapper against
  the real adapter and reports the median of the paired *differences*. Phases
  under it are below probe resolution and are not values of the uninstrumented
  request. Taking a difference of medians instead read 3.6 ms of "overhead"
  that was the box moving inside one arm.

`calibrate` injects a known sleep into one named callback and requires it to
appear in that interval and nowhere else. Run all five: injecting into one
proves that boundary and leaves a swap among the other four invisible.

### Many callers on a pool, and what they queue behind

`reqbench` drives a pool of script workers with many callers, the shape a host
like hornbeam serves in, and samples every 10 ms the message queue of each
node-wide process a request can wait on: `file_server_2`, the reaper, the
cleanup manager, the steward supervisor, the keeper and the code slots.

```sh
erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/reqbench.erl
REQBENCH_WARM=240 erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \
    -run reqbench main py 14 64 10 ""
```

The arguments are the guest (`py`, `qjs`, `lua`), the worker count, the caller
count, the seconds per arm and extra worker options as a term, for example
`"#{restore_ahead => true}"`. Images and generated code are kept under
`_build/reqbench`, so warm it once with a long `REQBENCH_WARM` (CPython's tier
takes minutes the first time) and later runs load it in seconds.
Each guest runs at infinite fuel: until 2026-09-28 the `qjs`
and `lua` arms passed only `compile => true`, kept `untrusted()`'s finite fuel,
and so ran interpreted whatever the output said about the tier.
`REQBENCH_POOL=fifo` rotates idle workers instead of reusing the last one,
which is the case `restore_ahead` helps; `REQBENCH_MSACC=1` prints microstate
accounting for the loaded arm.

A queue whose maximum stays at 0 or 1 is not a serialisation point; one that
grows is. Like `throughput`, the requests per second are the box's as much as
the code's: compare two builds only interleaved, in the same minutes, each with
its own code cache (a cache under a symbolic link or a world-writable directory
such as `/tmp` is refused, and that arm silently interprets).

### What a store costs in generated code

`storebench` times a loop of `i32.store` and `i64.store` with the tier forced
on:

```sh
erlc -o bench/paths -I include -pa _build/default/lib/wasm/ebin \
    bench/paths/storebench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run storebench main plain
```

Run it before touching the inlined store in `wasm_core`, interleaved against
the previous build, and compare minimums: the difference is a few nanoseconds.

### How far compiled code is from plain Erlang

`gap` runs a kernel as hand-written Erlang, interpreted and compiled, one arm
per VM:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin \
    bench/paths/benchlib.erl bench/paths/allocwords.erl bench/paths/gap.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run gap main sieve native
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run gap main sieve compiled
```

Run the `null` kernel's `native` and `native_b` arms first: they are the same
code, and the difference between them is the box. `alloc_compiled` gives heap
words per unit, and `dump` writes `core.txt` and `wasm.S` to the current
directory so the compiled kernel's instructions can be read against
`erlc -S` of the Erlang arm. The table it produced for 0.7.0 is in `PERF.md`.

### Where a real guest's time goes

`guestprof` profiles a compiled QuickJS run or 50 CPython requests. Run it
before ranking engine work, because a kernel's gap says nothing about how
much of a guest's time sits there:

```sh
erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/benchlib.erl \
    bench/paths/reqbench.erl bench/paths/guestprof.erl
erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \
    -run guestprof main qjs count
```

The first VM compiles the guest into `_build/guestprof/code`, which takes
minutes. Every later VM must print `cached => 1` in its counts. `compiled`
counts a cache hit too, so it is not the check.

- `count` gives exact calls per function.
- `bigword` sorts every word `atomics:get/2` answers into small and bignum.
- `widths` counts memory accesses by width on the interpreter.
- `sample` prints the OS pid for macOS `sample <pid> 20 1`.

`+JPperf` is refused on macOS, so a sample shows generated code as bare
addresses; split that bucket with `count`, and call the split an estimate.

### Pool numbers on a laptop

A pool arm with more busy workers than performance cores measures the
scheduler of the OS as much as the runtime: on a 10+4 core M4 Pro with
background indexing running, one build's run fell from about 210 to 143 req/s
with the same reductions per request, and a rerun moved the collapse to
another build. Run pool arms with `+S 10:10` and at most ten workers, or
repeat the rounds and discard any whose reductions a second fall well below
that build's median, and say which.

## Comparing memory representations

These arms hold a change to linear memory, restore or the page budget against
the gates in `PERF.md`. Each runs one arm in one fresh VM from inside the tree
it measures, so run them interleaved across trees and give every tree its own
code cache. The guests come from `reactorlib`: `py`, `py_entry` (CPython with
an entry captured into the image, so a request is one function call, as
hornbeam makes it), `qjs`, `lua` and, where it makes sense, `plain`.

```sh
erlc -o bench/paths -I include -pa _build/default/lib/wasm/ebin \
     bench/paths/benchlib.erl bench/paths/reactorlib.erl \
     bench/paths/barrier_adapter.erl bench/paths/requestbench.erl \
     bench/paths/restorebench.erl bench/paths/densitybench.erl \
     bench/paths/optbshare.erl bench/paths/pagedbench.erl \
     bench/paths/instbench.erl
```

### One worker's request latency

`requestbench` times requests on a stock script worker. Its modes:

- `first`: the first request of a fresh node;
- `steady`: 20 warm-up requests interpreted, or requests until one enters
  generated code when compiled, then 200 timed;
- `split`: the worker's per-request sequence replayed through the public
  `wasm` API, each phase timed apart (`restore`, `post`, `call`, `destroy`);
- `firstwrite`: `split` on a tree built with the `arb_inst` counters, reading
  how many first writes a request paid and what they cost.

```sh
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run requestbench main steady py_entry compiled off \
        "$PWD/_build/cache-a" raw/steady.terms
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run requestbench main split py interp off none raw/split.terms
```

`split` and `firstwrite` need `restore_ahead` off and say `VOID` otherwise.
`firstwrite` is never a timed arm: the counters are a scratch build's, not the
tree under test. `ARB_SMOKE=1` cuts every count to a few requests, which
proves a harness runs and is never a sample.

### Restores, density and footprint

```sh
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run restorebench main all 200 20 raw/restore.terms
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run densitybench main density py_entry raw/density.terms
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run optbshare main py 50 raw/sharing.terms
```

- `restorebench` times `wasm:restore/3` and `wasm:load_snapshot/2` per guest.
- `densitybench density` counts the instances that fit under `page_limit`
  4096. A refusal counts when the budget gave it, at restore or during the
  call, since a restored memory takes its pages when it writes them.
- `optbshare` holds K instances and reports, per instance, `erlang:memory/0`
  and the VM's physical footprint and resident set. Use it rather than
  `densitybench sharing` when a backend maps memory outside the BEAM's
  allocators, which `erlang:memory/0` cannot see. It reads `footprint -p`, so
  it runs on macOS.

Density is a count, not a time: it does not move with load, and a ratio
other than 1.000 across rounds is a harness problem, not noise.

### Memory kernels and instantiation

```sh
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pagedbench main store paged compiled
erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run instbench main gget
```

`pagedbench` runs the `storebench` and `gap` sieve kernels over a plain memory
(`plain`) and over a restored one (`paged`). `instbench` times a fresh
`wasm:instantiate/3` for a module loaded through the cache (`const`), one
whose data segment sits at an imported global (`gget`), and one the cache
never saw (`uncached`). The kernels are the `.wat` files beside them,
encoded with `wasm-tools parse` into the `.wasm` files the arms load.

### Arbitrating between representations

When two representations are each defensible, settle it on a written rule
before measuring, then run every metric on every arm:

- **Williams order.** Each arm precedes each other arm once per block of
  rounds, so drift in the box does not land on one arm. Eight rounds for four
  arms is two blocks.
- **A load gate per cell.** A cell, one metric on every arm, starts below load
  8; if the load is 8 or more when its last arm ends, the cell is redone and
  the discarded files are kept.
- **Per-round ratios, then their median.** Each arm is compared to the
  reference within its round.

The scripts and results of the shared-pages arbitration are under
`test/audit/raw/shared-pages/arbitration/`, and the outcome is in `PERF.md`.