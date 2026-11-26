# Measuring

How to measure a change and turn the number into a claim someone else can
check. Use it whenever your change claims speed, memory or density, and
before you propose an optimisation at all.

This project keeps a measurement record, and a claim without an entry in it is
not accepted. `test/audit/PERF.md` holds every measured figure a claim cites;
`test/audit/ATTEMPTS.md` holds what was tried and dropped, with the numbers
that dropped it. Read the second first: several obvious ideas are already
there.

## Write the gates down first

Before you measure, write what would count as a win and what would count as a
regression: which arm, which statistic, which threshold. A gate set after the
numbers arrive can be made to say anything. Gate every cost the change can
move, not only the one it targets: a change that sped up calls once quadrupled
compile time because nothing measured compile time.

If a gate fails, find where and why before doing anything else, and report it.
Do not move the gate, and do not revert without saying so.

## Run an arm

The arms are in `bench/paths/`, one Erlang module each, and
`bench/paths/README.md` says what each one measures. Build the one you need
against the compiled tree and run it in its own emulator:

```sh
rebar3 compile
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/pathbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pathbench main null
```

Start with the `null` arm. Two sides that should be identical and are not tell
you what the machine is doing to you before any other number means anything.

## Compare two revisions

1. Build the other side somewhere else, never by rebuilding in place:

   ```sh
   mkdir -p /tmp/base && git archive main | tar -x -C /tmp/base
   (cd /tmp/base && rebar3 compile)
   ```

2. Check the load average: the 5-minute one, the second value `sysctl -n
   vm.loadavg` prints, which is what the arms record. The maintainer's
   machine has swung from 4 to 84 in one session; a run counts only if that
   average was below 8 when it started and when it ended, and is redone
   otherwise. If a script waits for the machine to be quiet before a run, it
   must wait on the same average it checks: one that waited on the 1-minute
   average launched short runs while the 5-minute one was still near 25, and
   threw every one of them away.
3. Run each side in a fresh emulator, one process per run. A long-lived
   process carries its heap into the next run, and QuickJS repeated in one
   process is bimodal, 1.7 or 13 seconds.
4. Interleave the two sides, and run both orderings, so a change in load lands
   on both.
5. Compare paired runs. Inside one launch an arm may take the minimum of its
   rounds; never compare minimums picked across launches.
6. For pool and throughput arms, pin the schedulers (`+S 10:10`) and use no
   more workers than performance cores.

## Time the call a user makes

Measure through the public function a user calls, and take any phase times
from inside that same call. `wasm:compile/1` sets a heap floor before it
decodes a module over 16 KiB; an arm that called the decoder and the
validator directly skipped it, reported a 69% validation slowdown that the
public call does not have, and an 18 to 28% validation gain that is 3 to 4%
through it. Add phase times up only within one call: minimums taken from
different rounds and added together describe a call that never happened.

## Decide on paired ratios

The rule the timed comparisons in `PERF.md` since 0.11.1 were held to,
written here so you can hold yours to it:

- Six pairs per ordering, twelve in all. A pair is one run of each side, each
  in a fresh emulator, one after the other; its ratio is the change's number
  over the baseline's.
- A null set first: the baseline against itself, the same way. It passes
  when the median of its paired ratios is between 0.95 and 1.05 in each
  ordering and neither side is bimodal. A set whose null fails is discarded
  and run again, at most three times; three failures make the result
  inconclusive, which is neither a win nor a loss.
- The decision is the median of the paired ratios, in each ordering; both
  must pass. Limits are one-sided: a win is "at or below X", a no-slowdown
  gate is "at or below 1.03" with no lower bound.
- A pair that gives up under the load rule after six attempts is run again
  under the same rule before you read a verdict. Report every pair, not only
  the medians.

Before a run that takes hours, feed the script's acceptance check one healthy
record, one from a failed run and one taken at high load, and see it accept
the first and refuse the other two. Two checks were wrong this way: one
matched `failed => 0` in the compile counters of every healthy run and threw
all of them away, the other lost the escape in its pattern and refused
everything.

## Use `realbench` for the interpreter

Anything on `wasm_exec`'s dispatch path (`run/3`, `branch/3`, `do_call/4`)
goes through `realbench` on QuickJS, five interleaved pairs, both orderings,
before you believe any other number. Three changes there cost about 70% on
QuickJS while the synthetic loop measured nothing.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/realbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run realbench main qjs
```

## Find where time goes before theorising

`matrix` records, per run, wall and CPU time, reductions, collections, heap
and node memory, and microstate accounting. Microstate accounting (`msacc`)
answers in one run whether lost time went to collection, the emulator, a NIF
or auxiliary work.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/matrix.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run matrix main qjs fresh 5
```

## Record it

- A result goes in `test/audit/PERF.md` in the same commit as the change: the
  question, the arm and command, the machine and load, the gates, the numbers
  and what they mean. Raw output goes under `test/audit/raw/`.
- A dropped idea goes in `test/audit/ATTEMPTS.md`, with the numbers that
  dropped it and what would make it worth trying again.
- A claim in a page or a pull request cites the `PERF.md` section.

## Read this next

`bench/paths/README.md` for the arms in detail, and `test/audit/README.md`
for the rest of the evidence.
