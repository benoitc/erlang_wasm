# Python

This page shows you how to run Python code that you receive at request time.
Read it to decide whether your Python code can run here, and to set the
limits: CPython needs several limits raised, and an adapter never raises a
limit without telling you.

A few words used on this page:

- a **worker** is a process that runs one request at a time with a deadline;
- an **adapter** is the module that teaches a worker one language, here
  `wasm_python_command` or `wasm_python`;
- the **tenant** is the person who writes the Python code you run;
- a **runner** is the process that runs the guest for one request.

The [glossary](concepts.md#glossary) defines the others.

## Run one

> **Where these modules come from.** `wasm_python_command`, `wasm_python` and
> the worker kernel they run on (`wasm_script_worker`) are installed with the
> application. You supply the CPython artifact, the `.wasm` file.

<!-- check: run -->
<!-- check: needs python -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python_command,
            #{path => "test/fixtures/lang/python.wasm",
              limits => #{timeout => 300_000,
                          max_memory_pages => 4096,
                          max_host_calls => 1_000_000,
                          max_heap_words => 16 * 1024 * 1024,
                          fuel => 4_000_000_000}}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
                           #{~"value" => 41}).
```

The tenant writes one function:

```python
def main(context):
    return {"answer": context["value"] + 1}
```

## Raise the limits

`wasm_limits:untrusted/0` is made for programs much smaller than an
interpreter. These defaults are too small for CPython:

| limit | why |
| --- | --- |
| `timeout` | a request takes tens of seconds, not one |
| `max_memory_pages` | 16 MiB is not enough memory for CPython |
| `max_heap_words` | the default **kills the runner** before the interpreter starts |
| `fuel` | 10,000,000 is used up before CPython runs its first line; 4,000,000,000 is measured to be enough |

**A bigger `max_heap_words` makes requests slower, not safer.** Use 16M words.
With 64M and 256M, a request took 85 s instead of 48 s. A larger limit lets
the heap grow more before each garbage collection, and then each collection
costs more. The limit is a maximum, not a size to aim for.

`test/fixtures/lang/PYTHON.md` has the other numbers, and the artifact they
were measured on.

## What you get

You get the language and the interpreter's bundled standard library. The
artifact measured here includes the library inside the `.wasm` file:
`sys.path` names a directory that no preopen (a directory the guest is allowed
to open) contains, and `import json` still works. So the worker declares
**one** mount. An upstream build that ships `python.wasm` next to a `Lib`
directory needs that directory as a second, read-only preopen.

The interpreter starts with `-I -B -u`:

- `-I`: isolated configuration;
- `-B`: no `.pyc` files written;
- `-u`: no output buffering.

`-u` is required, not a preference. Buffered output arrives all at once at the
end, so the limit on streamed output would never see it. `-I` also implies
`-P`, so the work directory is **not** on `sys.path`. The bootstrap loads your
module from an explicit path with `importlib.util.spec_from_file_location`. It
does not put a directory the tenant supplied on the import path.

## What you do not get

**Arbitrary PyPI wheels, or any native extension module.** Any code written in
C must be built for `wasm32-wasip1` and linked into the interpreter.

**`subprocess`, native threads, or normal socket support.** The runtime did not
remove these: **CPython itself disables them on the WASI platform**. WASI is a
Tier 3 platform in [PEP 11](https://peps.python.org/pep-0011/), and
[CPython's WebAssembly platform
notes](https://docs.python.org/3/using/wasm.html) say these features are
missing.

**Pyodide compatibility.** Pyodide targets Emscripten. It needs JavaScript glue
code, a browser ABI and a package loader that WASI preview 1 does not provide.
On a host that runs V8, that glue costs nothing. On the BEAM it only adds
problems. Do not expect a Pyodide package to run here unchanged.

**A network.** The worker denies network access on purpose; it is not
missing. To grant it, write a `wasi_net` rule that names addresses and ports.
Know what the limits control: `max_sockets` limits the sockets an instance
holds **at the same time**, and `timeout` limits **one blocking call**.
Neither one limits the total number of outgoing requests.

## It is slow, and the number is recorded

One request takes 53 to 76 s, interpreted, on a lightly loaded machine. The
conformance suite takes 29 minutes. That is too slow for a worker, and the
project says so: `test/fixtures/lang/PYTHON.md` records it, and
`wasm_worker_lang_SUITE` leaves the CPython groups out of its default run
because of it. The fix is a snapshot of the started runtime, not tuning.

A snapshot needs a **reactor**: a guest that exports `init()` and `handle()`
and stays ready between calls. The artifact measured here is a **command**,
with one `_start` that runs once and exits, so it can never use a snapshot.
The next section shows the reactor build.

## Skip the interpreter start, with the reactor build

**88 ms a request instead of a minute or more.** CPython starts once, when the
worker starts. The worker saves an **image** of the guest at that point, and
each request **restores** a fresh instance from that image. Build the reactor,
then give its path to a worker:

```sh
scripts/build-python-reactor.sh
```

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs python_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              capture_timeout => 300_000,
              limits => wasm_python:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{source => <<"def main(c):\n"
                                       "    return {'answer': c['value'] + 1}\n">>,
                           context => #{~"value" => 41}}).
```

For the tenant nothing changes: the same `main(context)`, the same JSON in and
out, the same capabilities.

Notes:

- **`start_link/2` takes about 14 seconds**, or 5 with the capture heap floor
  described below, because it starts the interpreter once. This happens once
  per worker, not once per request. Start your workers before you accept
  traffic. The example raises `capture_timeout` above its 60 s default,
  because a capture can take longer: 91 to 95 s without the floor, in the
  measurements below. A pool that prepares its image once with
  `wasm_script_worker:prepare/2` starts the interpreter once for the whole
  pool; see [Using workers](worker.md).
- **Isolation does not change.** A restore builds a *fresh* instance, so the
  module-level state of one request never reaches the next.
- **You give two paths.** The module needs its standard library next to it,
  and `lib` is where you give that path. The build script produces both.
- **The hash seed is in the image.** It is chosen once, during initialisation,
  and every request that restores the image shares it. You cannot choose a new
  seed later: string hashes are already cached with the old one. To change it,
  capture the image again. [Snapshots](snapshots.md) lists what else an image
  keeps fixed.
- **The build needs a WASI SDK, binaryen's `wasm-opt` and about twenty
  minutes.** The downloaded command artifact needs none of these.
  `test/fixtures/lang/PYTHON.md` has the pinned versions and says why there is
  no checksum.
- **The standard library is precompiled.** Every module in `lib` comes with
  its `.pyc`, so when your source imports a module, it loads bytecode and does
  not compile the module during your request. The `.pyc` files are "unchecked
  hash-based": an import never reads the `.py`, so editing a `.py` has no
  effect until you run the build script again.
- **Objects in the image are hidden from the cyclic garbage collector.** See
  [below](#the-image-is-hidden-from-the-collector).
- The numbers, the control measurement and where the time goes are in
  `test/audit/PERF.md`.

## The image is hidden from the collector

At the end of its start, the reactor calls `gc.collect()` and `gc.freeze()`. A
capture with an `entry` (see the next section) does it again after the entry
has run. Every object alive at that point moves to the collector's permanent
generation. So a collection during a request only visits the objects that the
request allocated. Without this, a collection that was due just after the
capture would run in every request.

What this means for your code:

- **`gc.get_objects()` does not list objects from the image.**
  `gc.get_freeze_count()` counts them. Objects that your request creates are
  listed as usual.
- **The cyclic collector never frees anything in the image.** Reference
  counting still frees an image object when its last reference goes, and its
  weakref callbacks run as usual. An object kept alive only by a reference
  cycle is never freed, and its callbacks never run. This is not a leak: the
  request's copy of the image is thrown away when the request ends.
- **Do not call `gc.unfreeze()`.** It gives the whole image back to the
  collector, and the next collection must visit all of it, in that request.

## Call a fixed entry instead of sending a source

Use this when the code is the same for every request and only the context
changes, for example when a host runs one application per worker. The worker
runs the code once, while it captures the image. Each request then calls a
function that is already in the image, so no code is compiled or imported
per request.

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs python_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              entry => <<"import worker\n"
                         "def answer(c):\n"
                         "    return {'answer': c['value'] + 1}\n"
                         "worker.set_entry(answer)\n">>,
              capture_timeout => 300_000,
              limits => wasm_python:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{context => #{~"value" => 41}}).
```

What to know:

- **Call `worker.set_entry(callable)` once, with one callable.** The capture
  runs `entry` as `/main.py`, so if it defines a `main`, that `main` is called
  once with `None`. A worker whose `entry` never calls `set_entry` does not
  start. A request that calls it again gets an `exception` error saying that
  the entry is already set.
- **A request without `source` calls the entry** with its context. A request
  with `source` runs that source, as on any reactor worker.
- **The entry's globals are fresh on every request.** Each request restores
  the image, so what one call changed is gone for the next request.
- **The context comes through an import**, `worker.context`, not as a file
  written for the request. Only `max_request_bytes` limits its size.
- **To change the code, restart the worker.** The entry is part of the image
  and of the image's version, so two workers with different entries never
  share a stored image.

The same request through `handle()` and through an entry, with the compiled
tier on, run one after the other in one emulator on a loaded machine: the
guest's call took 40.4 ms and 2.1 ms. [Tuning a worker host](tuning.md) has
the table.

## Give both processes a heap floor

A **heap floor** is a minimum heap size given to a process when it starts, so
the Erlang garbage collector runs less often. CPython gains more from it than
the other two guests here, and it gains twice: at the worker start and in each
request. `wasm_python` sets the floor of the request runner for you. The value
depends on the tier your limits select:

| tier | limits | `runner_min_heap_words` |
| --- | --- | ---: |
| compiled | `compile => true`, `fuel => infinity` | 1,500,000 |
| interpreted | anything else | 1,000,000 |

The compiled tier needs more. At 1,000,000 words, its heap still grew once
during a request, to 2.88 M words. At 1,500,000 it never grew: a request was
3 to 6% faster at p50, and a pool of ten answered 29 to 34% more requests,
against 17 to 24%. The interpreter gains nothing above 1,000,000. Both values
fit under `wasm_python:limits/0`, and under the untrusted preset with the
worker's extra margin.

The adapter does **not** set the floor for the capture. Add
`capture_min_heap_words` yourself, together with the larger `max_heap_words`
shown here:

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs python_reactor -->
```erlang
Limits = (wasm_python:limits())#{max_heap_words => 32 * 1024 * 1024},
{ok, W} = wasm_script_worker:start_link(
            wasm_python,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              capture_timeout => 300_000,
              limits => Limits,
              capture_min_heap_words => 2_000_000}).
```

| | without | with |
| --- | ---: | ---: |
| `start_link/2`, capturing | 91 to 95 s | **17.4 s** |
| a request | 367 ms | **118 ms** |

Both rows come from the heap floor measurements. The request row was measured
before the restore path stopped writing over zero pages that the image already
had. With the floors on, an interpreted request now takes **88 ms**, and 35 ms
once the compiled tier is in use. Compare two numbers from the same row only:
the rows come from different runs. The start row was measured before the
standard library was precompiled. With the precompiled library, one capture
took 13.6 s without the floor and 4.5 to 5.0 s with it.

[How a heap floor works](tuning.md#how-a-heap-floor-works) explains where the
options go (next to `root`, not in the map `wasm_python:limits/0` returns), why
there are two of them, and how a floor is rounded. What is specific to
CPython:

- **Without a floor, both processes run thousands of collections**, during
  work that allocates billions of words.
- **The capture needs twice as much as a request**, which is why the two
  floors are different.
- **Raise `max_heap_words` when you add the capture floor.** That is why the
  example above changes it, and why the adapter sets no capture default: a
  default cannot know that you raised the limit. At the adapter's own 16 M
  words, CPython is close to the limit, and a capture with a floor fails
  **some** of the time. Measured again on 0.7.0, with four fresh starts at
  2 M words: three captures died and one passed. A start that fails this way
  says `the capture died`, and its context names `max_heap_words` and the
  floor, so you can see the cause.
- **CPython's best request floor is five times that of QuickJS**, which is why
  each adapter has its own default. Pass `runner_min_heap_words` to change it,
  or `0` to turn it off. [The tuning guide](tuning.md) shows how to find the
  value for a different build.

## Errors

An exception in the tenant's code comes back as a value. The traceback is on
stderr and the message is in the error:

```erlang
{error, #{class := adapter, kind := adapter_failure,
          msg := ~"boom",
          ctx := #{code := ~"exception", stdout := _, stderr := _}}}
```

`code` is a **binary**. Nothing a guest names becomes an atom, because the atom
table is shared by the whole node and atoms are never freed.

## Read this next

[Tuning](tuning.md), then [Snapshots](snapshots.md).
