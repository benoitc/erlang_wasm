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

2. Check the load average. The maintainer's machine has swung from 4 to 84
   in one session; start below 8, and redo a run that ends above it.
3. Run each side in a fresh emulator, one process per run. A long-lived
   process carries its heap into the next run, and QuickJS repeated in one
   process is bimodal, 1.7 or 13 seconds.
4. Interleave the two sides, and run both orderings, so a change in load lands
   on both.
5. Compare paired runs. Inside one launch an arm may take the minimum of its
   rounds; never compare minimums picked across launches.
6. For pool and throughput arms, pin the schedulers (`+S 10:10`) and use no
   more workers than performance cores.

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
