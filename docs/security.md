# Security model

This page tells you what the runtime protects you against and what it leaves to
you. Read it before you put a module you did not write in front of user traffic.
The second list is the important one.

## What holds the boundary

A module cannot reach outside its sandbox, for five reasons:

- **Validation** proves every instruction is type-correct and every index is in
  range, before anything runs. The interpreter never re-checks what validation
  established.
- **Linear memory is bounds-checked** on every access, in arbitrary-precision
  integers, so a base near 2^32 plus a large offset cannot wrap into a valid
  address.
- **Imports are the only way out.** A module can do nothing but compute unless
  you hand it a function.
- **Nothing a guest supplies becomes an atom.** Not the module bytes, and not
  the strings it passes across the WASI boundary: host names, service names and
  paths. The atom table is node-wide and never reclaimed, so a guest able to
  mint one atom per call is a permanent leak and eventually a node kill,
  immune to every limit here. Both halves are asserted, because for a while
  only the first was true: `sock_getaddrinfo` resolved a guest-chosen service
  name through `binary_to_atom/2` while the decoder's property test passed
  next door. `wasm_prop_SUITE` now covers both, and asserts that atoms do not
  scale with the number of distinct strings a guest sends.
- **Nothing raises.** Malformed input, ill-typed modules, traps and exhausted
  limits are all values. Property tests over random binaries, and over valid
  modules mutated byte by byte, verify it.

None of this depends on processes. Your inline call is exactly as sandboxed as a
call inside a worker.

## What limits bound

| limit | bounds |
| --- | --- |
| `fuel` | execution work, charged at calls and loop back-edges |
| `max_depth` | WebAssembly call depth |
| `max_heap_words` | Erlang terms on the owning process's own heap, applied by it. Not linear memory, not the object store |
| `max_host_calls` | calls out through an import, per invocation |
| `max_memory_pages` | every memory one instance can reach, imports included |
| node page budget | linear memory across every instance |
| `max_rec_groups` | distinct recursive type groups interned node-wide |

`max_memory_pages` counts an imported memory, because a module that imports one
can address every page of it, and it counts a memory once however many import
slots name it. A memory two instances share grows only as far as the stricter
of their ceilings allows.

`max_rec_groups` bounds a table whose rows can never be removed: a type id is
compared by `ref.eq` and by import matching, so dropping one would make two
different types the same for whatever module still holds it. A module that would
push the node past the limit is refused with `too_many_rec_groups`. The default
is 100,000 and a real module declares tens.

`fuel`, `max_depth` and `max_host_calls` belong to the invocation the embedder
started, not to each entry into the interpreter. A guest that recurses by
calling out through an import and back in is bounded by the same allowance as
one that recursed directly.

## What you are still responsible for

Stated plainly, because "each instance is in a process, so it is isolated" is
the most tempting wrong claim available about this design. A process is a
**fault and lifecycle** boundary, not a security boundary.

1. **Neither linear memory nor the object store is on any process heap, so
   `max_heap_size` bounds neither.** Linear memory is `atomics`; a struct or an
   array is a row in ETS. Both are counted explicitly by `wasm_engine` instead,
   which is what `max_memory_pages` and the node page budget bound. A guest
   filling a twenty-million element array took 1.8 GB before the object store
   was counted, with every limit reading zero.

1. **Linear memory is invisible to `max_heap_size`.** It is `atomics`, which is
   off-heap. A module can exhaust node memory without its process heap moving.
   This is why page accounting is explicit and node-wide, and why you should set
   `wasm_engine:set_page_limit/1`.

2. **Per-instance limits do not bound concurrency.** No single instance can
   monopolise a scheduler, because the interpreter is preemptible: every
   dispatch step is an Erlang function call and consumes a reduction. But ten
   thousand well-behaved instances will still saturate every scheduler. Bound
   that with a pool.

3. **Host functions are the real attack surface.** Limits constrain
   WebAssembly, not the Erlang you supply as an import. A host function that
   reads any file, allocates without bound, or blocks forever is outside all of
   this. The import set is part of your sandbox, and the part the runtime cannot
   check for you.

4. **`fuel` bounds work, not time.** A blocking host call consumes none. You
   need a timeout as well, and a timeout needs a process to enforce it. The
   same goes for a guest that parks in `memory.atomic.wait` with a negative
   timeout, which the specification defines as waiting forever: it consumes no
   fuel and nothing here will interrupt it.

5. **A start function that traps keeps its instance.** The specification
   requires it: the store keeps what instantiation wrote, so a module that
   fills an imported memory and then traps has to leave those bytes behind.
   The pages, tables and globals it took stay held. In a long-lived builder
   that instantiates many modules, a hostile one can repeat this until the node
   budget is gone.

   The instance comes back in the error so you can end it when you know nothing
   escaped:

   ```erlang
   case wasm:instantiate(Mod, Imports) of
       {ok, Inst} ->
           {ok, Inst};
       {error, #{ctx := #{instance := Inst}} = Error} ->
           ok = wasm:destroy(Inst),
           {error, Error};
       {error, Error} ->
           {error, Error}
   end.
   ```

   Do not destroy it if another instance imported something from this one and
   may still reach what it wrote. Building each instantiation in its own
   short-lived process is the other answer, and the one `docs/worker.md`
   already recommends.

6. **Timing and microarchitectural side channels are not addressed.** Nothing
   here stops a co-tenant module measuring shared cache behaviour. A shared BEAM
   node is not a boundary against that class of attack; only OS-level or
   hardware separation is.

7. **An inline call cannot be interrupted.** `wasm:call/3` runs in your process.
   A module looping with `fuel => infinity` hangs you and cannot be killed
   without killing you. Use a worker for anything untrusted.

8. **WASI path resolution has a residual race without the NIF.** On the
   `fallback` backend, a component can be swapped for a symlink between the
   check and the open. Check `wasi_fs:backend()`; on `fallback`, do not point a
   preopen at a directory a hostile party can write to concurrently.

   A preopen is also a directory rather than a name on the native backend,
   opened once when the capability is granted. Replacing the host directory
   underneath a running instance used to redirect every path it held.

   This is only now true of what a guest does. `path_open` resolved the path
   and opened it as two separate steps whichever backend was present, so the
   native one guarded nothing a guest could reach and every deployment had the
   fallback's race. A guest open goes through `wasi_fs` now, and
   `wasi_SUITE` asserts it by a behaviour only the native backend has.

## What a network grant does not cover

A `net` grant says which addresses an instance may reach. That is all it says,
and the gap between that and "the module cannot do harm over the network" is
yours to close.

1. **A granted peer gets whatever the module sends it.** The grant is an address
   filter, not a protocol filter: nothing inspects, limits or understands the
   bytes. If a module can reach a host, it can send that host anything it has,
   including data it read from a preopened directory.

2. **There are no implicit denials.** `~"0.0.0.0/0"` really does include
   loopback, link-local, RFC 1918 space and the cloud metadata endpoint at
   `169.254.169.254`. That is deliberate: a hidden deny list makes a grant mean
   something other than what it says, and the day it is incomplete is the day
   somebody relies on it. Name what you mean, and prefer a CIDR to a wildcard.
   `wasi_net_escape_SUITE` asserts this, so it stays true or this document gets
   corrected with it.

3. **Nothing here authenticates an inbound connection.** A `listen` grant opens
   a socket; whoever reaches it is whoever can route to it. The peer address is
   reported, never checked against the `connect` rules, because inbound is not
   outbound. Authentication is your module's problem or your network's.

4. **A blocking socket call consumes no fuel.** This is point 4 above with a
   much sharper edge: a module parked in `sock_recv` does no work. The `timeout`
   in the grant bounds a single call, not a sequence of them, so a module that
   reconnects in a loop waits forever in instalments. Use a worker with a
   timeout for anything untrusted.

5. **Descriptors are bounded, bandwidth is not.** `max_sockets` caps how many
   sockets an instance holds at once. Nothing caps how much it sends through
   them, how fast it opens and closes them, or how many instances you run.

6. **Resolution is a lookup, not a permission.** `resolve => allow` lets a
   module ask your resolver questions, which is an outbound capability of a
   kind: it reaches your DNS servers, and the names it asks for are visible to
   them. What it cannot do is widen a `connect` grant, because grants name
   addresses and `sock_connect` checks the address it is handed.

7. **The socket extension is not a specification.** Preview 1 standardised four
   socket calls; everything a client needs is a WasmEdge extension bound under
   the same module name, and its structure layouts are somebody else's decision.
   They are implemented from WasmEdge's headers, and they can change there. See
   [wasi.md](wasi.md).

## Run untrusted code

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),
{ok, W}   = wasm_worker:start_link(Mod, #{limits => wasm_limits:untrusted(),
                                          isolation => fresh,
                                          imports => MinimalImports}),
{ok, R}   = wasm_worker:call(W, ~"handle", [Req], 500).
```

Check all five before you ship it:

- `isolation => fresh`, so no state survives a request
- a timeout that kills the worker rather than merely giving up on it
- the smallest import set that does the job
- `wasm_engine:set_page_limit/1` set for the node
- a bounded pool, so concurrency is capped

## Reporting

Found something? Open an issue marked security, or contact the maintainer
directly.
