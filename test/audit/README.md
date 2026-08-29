# The audit, and the probes that back it

Two rounds of audit against `release-0.3.0`. Read `REVIEW.md` for the findings
and `PERF.md` for where the interpreter's time goes. Everything claimed in
either was reproduced by a probe in `probes/`, and the probes are here so the
claims can be checked rather than believed.

## Running a probe

They are ordinary modules driving the public API, not a test suite: each one
prints what it observed, and several are expected to print the *broken*
behaviour when run against the commit that had the defect.

```sh
erlc -o /tmp -pa _build/default/lib/wasm/ebin test/audit/probes/p6_pd.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa /tmp \
    -eval 'p6_pd:run(), init:stop().'
```

Some need the test beams as well, for a fixture module:

```sh
erl -noshell -pa _build/default/lib/wasm/ebin \
    -pa _build/test/lib/wasm/test -pa /tmp -eval 'p5_sock:run(), init:stop().'
```

## What each one shows

| probe | finding |
| --- | --- |
| `p1_cache` | a dead loader never gave its claim back; holders climbed to 21 |
| `p3_size` | `erts_debug:size/1` took 24 s where `size_shared/1` took 34 ms |
| `p4_race2` | two concurrent loads: one returned, the other *exited* |
| `p5_sock` | five instances destroyed, five sockets still open, peers still connected |
| `p6_pd` | a calling process accumulated 2,980 IR entries for destroyed instances |
| `p8_wait2` | killing one waiter destroyed the table and stranded another |
| `r1_mutof` | `function_clause` in `cache_fill/3` from a cold cache |
| `r2_pages` | two importers destroyed took the page counter to 2^64-1 |
| `r3_limits` | a 300-page module instantiated under a 256-page limit |
| `v1_cache` | the module cache fixes, verified after |
| `v2_wait` | the waiter table fixes, verified after |

## Short notes

- `r2_pages` poisons the node's page counter by design. Anything measured in
  the same VM afterwards is measuring the poison, which is how a first run of
  `r3_limits` produced a wrong conclusion. Give each one its own VM.
- A probe that no longer reproduces is evidence a fix landed, not evidence the
  probe was wrong. Check the commit before assuming.

## Final verification

Run before the release, against `16e7c1e` and after:

- Every probe above, each in a clean VM. `r2_pages` and `r3_limits` no longer
  reproduce; `p1_cache`, `p4_race2`, `p5_sock`, `p8_wait2` and `r1_mutof` show
  the fixed behaviour. `p6_pd` still shows the process dictionary growing and
  then being swept, which is what it does.
- A reachability check per mechanism: is it called from where the
  documentation says it applies? This is the one that mattered. It is what
  found `wasi_fs` having no callers at all while two pages described the
  window it closed, and it is cheap enough to run every time.
- The concurrency suites three times over: threads, leases, resources, module
  cache.
- `bench/paths` against the numbers in its README, as a sanity check rather
  than a measurement. The box has to be quiet for those to mean anything.
- The full suite twice, `rebar3 dialyzer`, `rebar3 xref`, and
  `rebar3 ct --suite=test/wasm_spec_SUITE` on its own, which runs without the
  application started.
- `./scripts/sanitize.sh` for the NIF under AddressSanitizer.

Not done: ThreadSanitizer over the NIF, which needs an emulator built with it.
The close-against-read race is covered by a test instead, and that test is what
found the defect.
