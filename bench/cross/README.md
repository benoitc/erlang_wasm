# Comparing this runtime against others

The same WebAssembly module through four runtimes, so the axis is the runtime
and nothing else. Use it when you want to know what interpreting on the BEAM
costs against a C interpreter and against a JIT, and to reproduce the numbers
in `test/audit/PERF.md` rather than take them on trust.

## What it is

`loop.wat` is a counted loop of integer arithmetic exporting
`bench(n) -> i32`. Every runtime runs the same compiled bytes and returns the
same checksum, which is what makes the comparison meaningful: if the results
diverge, the measurement is wrong and the numbers mean nothing.

## Build the module

```sh
wasm-tools parse bench/cross/loop.wat -o bench/cross/loop.wasm
```

## Run every arm at once

One command, one implementation of the protocol, every runtime measured the
same way:

```sh
erlc -o bench/cross -pa _build/default/lib/wasm/ebin \
    bench/cross/loop_erl.erl bench/cross/xrun.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/cross \
    -run xrun main bench/cross/loop.wasm 1000000
```

It prints one line per arm and, last, the checksum every arm returned at the
common size. **If an arm disagrees the run aborts**, because runtimes that
disagree are not running the same work and no number above that line means
anything. At `n = 1000000` the value is `-1803823781`.

## Run one arm on its own

`erlang_wasm` alone, with the per-size detail the table leaves out:

```sh
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/cross \
    -run loop_erl main bench/cross/loop.wasm 1000000
```

The others, at a single size:

```sh
wasm3    --func bench      bench/cross/loop.wasm 1000000
wasmtime --invoke bench    bench/cross/loop.wasm 1000000
node     bench/cross/loop.js bench/cross/loop.wasm 1000000
```

A single size is for checking the checksum, not for taking a number off.

## The protocol, and why the numbers moved

Every arm is measured the same way, and every part of this is there because
leaving it out gave a wrong answer at least once:

- **The JIT is asserted, not checked.** `loop_erl` and `xrun` both open with
  `jit = erlang:system_info(emu_flavor)`, a failing match. An interpreter-only
  build produces numbers that belong in no table here, and nothing used to
  notice.
- **Five sizes and a fitted slope**, not two sizes subtracted. Compilation,
  instantiation and per-call overhead go into the intercept where they belong.
  The fit reports r2, which is the run telling you whether a straight line was
  the right model; anything below about 0.99 means the box was busy and the
  number is not usable.
- **Repeated samples per size**, minimum reported, dispersion reported next to
  it. `loop_erl` prints the spread per size for exactly this reason.
- **Warmup inside the process** for `erlang_wasm`, because the first call
  lowers the body to IR and caches it. That cost belongs to no iteration.
- **A size ladder calibrated per arm.** One ladder for four runtimes cannot
  work: a size where this interpreter runs for a tenth of a second is a size
  where V8 does a millisecond of work behind thirty of process spawn. Measured
  that way the fit for node came back with an r2 of `0.11`, which is the fit
  refusing the number. Each arm now grows its ladder until it spends at least
  400 ms on iterations.

Recorded on an Apple M4 Pro at load average 4.5 to 5.3, wasm3 0.5.0, wasmtime
47.0.2, node 22, OTP 29, three full runs, minimum of each arm. Every arm fitted
above r2 0.997:

| runtime | kind | ns/iteration | top size |
| --- | --- | ---: | ---: |
| wasmtime | JIT | 0.77 | 625,000,000 |
| node (V8) | JIT | 1.56 | 625,000,000 |
| wasm3 | interpreter, C | 4.15 | 125,000,000 |
| erlang_wasm | interpreter, BEAM | 60.54 | 25,000,000 |

**wasm3 is the only like-for-like arm**, and it is 15x faster. It was 28x
before the bounded operand cache; see `test/audit/PERF.md`. The JIT arms are
interesting for cold start, where compilation is on their side of the ledger,
not for steady state.

The earlier table read 129.5 for `erlang_wasm`, 4.30 for wasm3 and 2.08 for
node. Those came from two sizes and five launches, and every one of them was
wrong by more than most changes worth arguing about. **The protocol moved our
own arm by 11% and node's by 25%.** That is the case for the protocol, and it
is why numbers taken the old way are not comparable with numbers taken this
way.

## Short notes

- The box matters. Recorded here at load average around 5; the same box at load
  30 moved control runtimes by 17% between runs, which is larger than most
  differences worth arguing about.
- A full run takes about a minute and a half, most of it in the JIT arms:
  625,000,000 iterations five times over at five sizes is where the resolution
  comes from.
- `fusecount` in `bench/paths/` counts which superinstruction rules fire on a
  module. This loop exercises two of the nine, so a fusion change has to be
  counted there and timed here.
- `erlang_wasm`'s figure is measured inside an already-running VM, which is the
  realistic case for an embedded library. The CLI arms include process spawn,
  which is the realistic case for them. Cold start is not comparable without
  saying which of those you mean.
