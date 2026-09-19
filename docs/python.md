# Python

Run Python that arrives at request time. You need this page when you are
deciding whether the thing you want to run can run here, and when you are
setting limits: CPython needs several of them raised, and an adapter never
raises a ceiling behind your back.

## Run one

> **Where these modules come from.** `python_worker`, `py_adapter`,
> `py_reactor_adapter` and the worker kernel they run on (`script_worker`,
> `worker_reaper`, `script_v1` and `worker_error`) are in `examples/` in this
> release, not installed with the application. From a checkout of this
> repository, `rebar3 as test shell` compiles them and puts them on the path.
> In your own project, copy those files from `deps/wasm/examples/` into your
> `src/`.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/py"}),
{ok, W} = python_worker:start_link(
            "test/fixtures/lang/python.wasm",
            #{root => scratch,
              limits => #{timeout => 300_000,
                          max_memory_pages => 4096,
                          max_host_calls => 1_000_000,
                          max_heap_words => 16 * 1024 * 1024}}),
{ok, #{result := #{~"answer" := 42}}} =
    python_worker:run(W, ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
                      #{~"value" => 41}).
```

The tenant writes one function:

```python
def main(context):
    return {"answer": context["value"] + 1}
```

## Raise the ceilings knowingly

`wasm_limits:untrusted/0` is built for something much smaller than an
interpreter. Three of its defaults will not do:

| limit | why |
| --- | --- |
| `timeout` | a request is tens of seconds, not one |
| `max_memory_pages` | 16 MiB does not hold CPython |
| `max_heap_words` | the default **kills the runner** before the interpreter starts |
| `fuel` | 10,000,000 does not reach CPython's first line; 4,000,000,000 is measured to be enough |

**A bigger `max_heap_words` is slower, not safer.** Measured on this box: 16M
words ran a request in 48.3 s, 64M took 85.3 s, and 256M took 84.5 s. A larger
bound lets the heap grow before a collection and the collection then costs
more. A ceiling is not a target.

Those are single runs, and this box is noisy enough that a request costs
anywhere from 53 to 76 s when the measurement is repeated and interleaved. Use
16M; do not read the other two as a precise ratio.

`test/fixtures/lang/PYTHON.md` has the rest of the numbers and what artifact
they were taken on.

## What you get

The language, and the interpreter's bundled standard library. The artifact this
is measured against embeds it: `sys.path` names a directory that is in no
preopen and `import json` works anyway, so the worker declares **one** mount.
An upstream build that ships `python.wasm` beside a `Lib` directory needs that
directory preopened read-only as a second mount.

The interpreter is started `-I -B -u`: isolated configuration, no `.pyc`
writes, no output buffering. The third is a bound rather than a preference,
because buffered output arrives in one burst at the end and the streaming limit
never sees it. Because `-I` implies `-P`, the work directory is **not** on
`sys.path`, and the bootstrap loads your module through
`importlib.util.spec_from_file_location` against an explicit path rather than
putting a tenant-supplied directory on the import path.

## What you do not get

**Arbitrary PyPI wheels, or any native extension module.** Anything with C in
it has to be built for `wasm32-wasip1` and linked into the interpreter.

**`subprocess`, native threading, or ordinary socket support.** This is not
something the runtime took away: **CPython itself disables them on the WASI
platform**, which is Tier 3 in
[PEP 11](https://peps.python.org/pep-0011/) and documented as lacking those
facilities in [CPython's WebAssembly platform
notes](https://docs.python.org/3/using/wasm.html).

**Pyodide compatibility.** Pyodide targets Emscripten and needs JavaScript
glue, a browser ABI and a package loader WASI preview 1 does not provide. On a
host whose engine is V8 that glue costs nothing; on the BEAM it is pure
liability. Nothing here should imply a Pyodide package runs unchanged.

**A network.** Denied by choice rather than missing. Granting it is a
`wasi_net` rule naming addresses and ports, and note what the knobs bound:
`max_sockets` caps the descriptors an instance holds **at once**, `timeout`
bounds **one blocking call**. Neither is a subrequest budget.

## It is slow, and the number is written down

53 to 76 s for one request, interpreted, on a lightly loaded machine, and 29
minutes for the conformance suite. That is not a
worker, and saying so is the point: `test/fixtures/lang/PYTHON.md` records it,
`wasm_worker_lang_SUITE` keeps the CPython groups out of its default run
because of it, and initialized runtime snapshots are the answer rather than
tuning.

A snapshot needs a **reactor** exporting `init()` and `handle()`. The artifact
measured here is a command with one `_start`, so it can never support one. The
next section is how to stop paying for that.

## Skip the interpreter start, with the reactor build

**0.12 s a request instead of a minute or more.** CPython starts once when the
worker starts, and each request restores an image of that point. Build it, then
point a worker at it:

```
scripts/build-python-reactor.sh
```

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/py"}),
{ok, W} = script_worker:start_link(
            py_reactor_adapter,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              root => scratch,
              limits => py_reactor_adapter:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    script_worker:run(W, #{source => <<"def main(c):\n"
                                       "    return {'answer': c['value'] + 1}\n">>,
                           context => #{~"value" => 41}}).
```

The tenant contract is unchanged: the same `main(context)`, the same JSON in
and out, the same capabilities.

Notes:

- **`start_link/2` takes 83 to 90 seconds**, or 17 with the capture floor
  below, because that is one interpreter start. It happens once per worker, not
  once per request, and a host should start its workers before it starts taking
  traffic.
- **Isolation is unchanged.** A restore builds a *fresh* instance, so one
  request's module-level state never reaches the next.
- **Two paths, not one.** The module needs its standard library beside it, and
  `lib` is where you say so. The build script produces both.
- **The hash seed is in the image**, drawn once during initialisation and
  shared by every request that restores it. Re-seeding afterwards is not
  available: string hashes are already cached against the old secret, so
  rotation means recapturing. `docs/snapshots.md` covers what else an image
  freezes.
- **It needs a WASI SDK and about twenty minutes to build**, which the fetched
  command artifact does not. `test/fixtures/lang/PYTHON.md` has the pins and
  says why there is no checksum.
- The numbers, their null experiment and where the time goes are in
  `test/audit/PERF.md`.

## Give both processes a heap floor

CPython gains more from this than either other guest here, and it gains on both
halves: the start and the request.

```erlang
Limits = (py_reactor_adapter:limits())#{max_heap_words => 32 * 1024 * 1024},
{ok, W} = script_worker:start_link(
            py_reactor_adapter,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              root => scratch,
              limits => Limits,
              runner_min_heap_words  => 1_000_000,
              capture_min_heap_words => 2_000_000}).
```

| | without | with |
| --- | ---: | ---: |
| `start_link/2`, capturing | 92 s | **17 s** |
| a request | 367 ms | **118 ms** |

Both processes keep almost nothing on their own Erlang heap, because the
module is a cache handle and the interpreter's memory is off-heap. The
collector sizes a heap from the live set, so it gives them the emulator's 233
words and then collects thousands of times through work that allocates
billions.

Three things to know:

- **The two options sit beside `root`, not inside `limits`.** A floor is not a
  bound, and one written into the map `py_reactor_adapter:limits/0` returns is
  ignored silently.
- **They are separate settings because they are separate processes.** CPython
  wants twice as much to capture as to answer, and a worker reading its image
  from `snapshot_dir` never captures at all, so it pays for the first and uses
  only the second.
- **Raise `max_heap_words` when you add the capture floor**, which is why the
  example above overrides it. `max_heap_words` bounds the peak and a floor
  raises the baseline that peak is measured from, so a ceiling that was
  comfortable without one can stop being comfortable with it. CPython at the
  adapter's own 16 M words is close enough to the edge that a floored capture
  dies **some** of the time: three runs in four, then a pass. A start that
  fails that way says `the capture died`, and names `max_heap_words` and the
  floor in its context so it is not a mystery.
- **CPython's request knee is five times QuickJS's**, which is why neither has
  a default. [The tuning guide](tuning.md) is how to find one for a different
  build.

## Errors

A tenant exception arrives as a value, with the traceback on stderr and the
message in the envelope:

```erlang
{error, #{class := adapter, kind := adapter_failure,
          msg := ~"boom",
          ctx := #{code := ~"exception", stdout := _, stderr := _}}}
```

`code` is a **binary**. Nothing a guest names becomes an atom, because the atom
table is node-wide and never reclaimed.
