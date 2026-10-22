# Security model

This page tells you what the runtime protects you against, and what you must
handle yourself. Read it before a module you did not write handles requests
from users. The second list ("What you are still responsible for") is the
important one.

**Do you need this?** Yes, before you run any module you did not write.

## The words on this page

| word | what it means here |
| --- | --- |
| **sandbox** | the limits that keep a guest module away from everything you did not give it. |
| **linear memory** | the guest's own memory: one array of bytes, stored in `atomics`, outside any process heap. |
| **object store** | where garbage-collected guest objects (structs and arrays) live: rows in an ETS table. |
| **atom table** | the node-wide table of Erlang atoms. An atom is never freed. |
| **trap** | the guest stopped on an error the specification defines. You get it as a value. |
| **page budget** | the node-wide limit on linear-memory pages, set with `wasm_engine:set_page_limit/1`. |
| **fuel** | a work budget: the guest stops when it has done that much work. |
| **worker** | a process that owns an instance and can be killed when a call takes too long. See [Using workers](worker.md). |
| **grant** | a permission you give a WASI guest, such as a directory or an address. See [WASI](wasi.md). |

More terms are in the [glossary](concepts.md#glossary).

## What holds the boundary

A module cannot reach outside its sandbox, for five reasons:

- **Validation** proves, before anything runs, that every instruction has the
  right types and every index is in range. The interpreter does not check
  these things again.
- **Every access to linear memory is checked against its size.** The check
  uses Erlang's unlimited-size integers. So an address near 2^32 plus a large
  offset cannot wrap around to a valid address.
- **Imports are the only way out.** A module can only compute, unless you give
  it a function.
- **Nothing a guest supplies becomes an atom.** Not the module bytes, and not
  the strings it passes to WASI: host names, service names and paths. The atom
  table is shared by the whole node and is never freed. A guest that can create
  one atom per call leaks memory forever, and finally stops the node. No limit
  on this page can prevent that. Both cases are tested, because for a time only
  the first was true: `sock_getaddrinfo` converted a service name chosen by the
  guest with `binary_to_atom/2`, while the property test for the decoder
  passed. `wasm_prop_SUITE` now tests both. It checks that the number of atoms
  does not grow with the number of different strings a guest sends.
- **Nothing raises.** Malformed input, ill-typed modules, traps and exhausted
  limits all come back as values. Property tests check this on random binaries,
  and on valid modules changed one byte at a time.

None of this depends on processes. A call in your own process is in the same
sandbox as a call inside a worker.

## What limits bound

| limit | bounds |
| --- | --- |
| `fuel` | execution work, counted at each call and each jump back to the start of a loop |
| `max_depth` | WebAssembly call depth |
| `max_heap_words` | Erlang terms on the owning process's own heap, applied by it. Not linear memory, not the object store |
| `max_host_calls` | calls out through an import, per invocation |
| `max_memory_pages` | every memory one instance can reach, imports included, and the object store it shares |
| node page budget | linear memory and object stores across every instance; for a restored memory, its page table and the pages it has written |
| `max_rec_groups` | distinct recursive type groups stored for the whole node |

`max_memory_pages` counts an imported memory, because a module that imports a
memory can use every page of it. A memory is counted once, even if several
imports name it. When two instances share a memory, it can grow only up to the
lower of their two limits.

`max_memory_pages` counts the garbage-collected object store in the same way.
A struct or an array is a row in ETS, and ETS is not on any process heap. So
`max_heap_words` cannot see it, and neither can the BEAM. The runtime
*measures* the size of a store, so the count follows what the store really
holds. Linked instances share one store, and the lower of their limits
applies. Because of this, `pages_in_use` can be a little above the node
budget: pages already used are counted even when the budget is exceeded. While
it is over, every new request for pages is refused.

`max_rec_groups` limits a table whose rows can never be removed. A type id is
compared by `ref.eq` and when imports are matched. If a row were removed, two
different types could become the same for a module that still uses them. A
module that would take the node past the limit is refused with
`too_many_rec_groups`. The default is 100,000. A real module declares a few
tens.

`fuel`, `max_depth` and `max_host_calls` count for the whole call that the
embedder started, not for each entry into the interpreter. A guest can call
out through an import, and the import can call back into the guest. This
recursion uses the same budget as direct recursion.

## What you are still responsible for

Many people think: "each instance is in a process, so it is isolated". This
is wrong. A process is a boundary for **failures and lifetime**, not a
security boundary.

1. **Neither linear memory nor the object store is on any process heap, so
   `max_heap_size` limits neither.** Linear memory is `atomics`. A struct or
   an array is a row in ETS. A module can use up the node's memory while its
   process heap does not grow. So `wasm_engine` counts both itself, and
   `max_memory_pages` and the node page budget limit that count. Set the
   budget with `wasm_engine:set_page_limit/1`. Before the object store was
   counted, a guest that filled an array of twenty million elements used
   1.8 GB, and every limit showed zero. A snapshot's image is stored in
   binaries outside the heap, shared by every instance restored from it, and
   limited by `max_snapshot_bytes`. An instance never writes to them. Its
   first write to a page copies that page into its own memory. So one
   tenant's writes never reach another tenant restored from the same image.

2. **Limits on one instance do not limit how many run at once.** No single
   instance can keep a scheduler for itself, because the interpreter can be
   paused: every step is an Erlang function call and uses a reduction. But ten
   thousand well-behaved instances will still keep every scheduler busy. Limit
   that with a pool.

3. **Host functions are where attacks happen.** Limits apply to WebAssembly,
   not to the Erlang functions you give as imports. A host function that reads
   any file, allocates without limit, or blocks forever is outside all of
   these protections. Your imports are part of your sandbox, and the runtime
   cannot check them for you.

4. **`fuel` limits work, not time.** A blocking host call uses no fuel. You
   also need a timeout, and a timeout needs a process to enforce it. The same
   is true for a guest that waits in `memory.atomic.wait` with a negative
   timeout. The specification says this waits forever. It uses no fuel, and
   nothing in the runtime will interrupt it.

5. **When a start function traps, its instance stays.** The specification
   requires this: the store keeps what instantiation wrote. So a module that
   fills an imported memory and then traps must leave those bytes there. The
   pages, tables and globals it took stay in use. A long-lived process that
   instantiates many modules is at risk: a hostile module can do this again
   and again until the node budget is used up.

   The error contains the instance, so you can destroy it when you know that
   nothing else uses it:

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

   Do not destroy it if another instance imported something from it and may
   still use what it wrote. The other solution is to instantiate each module
   in its own short-lived process, as `docs/worker.md` recommends.

6. **Timing and microarchitectural side channels are not handled.** Nothing
   here stops a module from measuring how the CPU cache behaves when other
   modules run beside it. A shared BEAM node does not protect against this
   kind of attack. Only separation by the operating system or the hardware
   does.

7. **A call in your own process cannot be interrupted.** `wasm:call/3` runs in
   your process. A module that loops forever with `fuel => infinity` blocks
   your process, and you cannot kill it without killing your process. Use a
   worker for any code you do not trust.

8. **Without the NIF, WASI path resolution still has a race.** On the
   `fallback` backend, someone can replace a path component with a symlink
   between the check and the open. Check `wasi_fs:backend()`. On `fallback`,
   do not use a preopen on a directory that a hostile party can write to at
   the same time.

   On the native backend, a preopen is a directory, not a name. It is opened
   once, when you grant it. So if someone replaces the host directory while an
   instance runs, the instance's paths still point to the original directory.
   A guest's `path_open` goes through `wasi_fs` and gets this protection.
   `wasi_SUITE` tests it with a behaviour that only the native backend has.

## What a network grant does not cover

A `net` grant says which addresses an instance may reach. It says nothing
more. A module can still do harm over the network, and you must prevent that
yourself.

1. **An allowed peer receives whatever the module sends.** The grant filters
   addresses, not protocols. Nothing reads, limits or understands the bytes. If
   a module can reach a host, it can send that host any data it has, including
   data it read from a preopened directory.

2. **Nothing is denied unless you deny it.** `~"0.0.0.0/0"` really includes
   loopback, link-local addresses, RFC 1918 private addresses and the cloud
   metadata endpoint at `169.254.169.254`. This is intended. A hidden deny list
   would make a grant mean something other than what it says, and when that
   list is incomplete, someone who relies on it is exposed. Name exactly what
   you mean, and use a CIDR rather than a wildcard. `wasi_net_escape_SUITE`
   tests this, so if the behaviour changes, this page must change too.

3. **Nothing here authenticates an incoming connection.** A `listen` grant
   opens a socket, and anyone with a network route to it can connect. The peer
   address is reported, but never checked against the `connect` rules, because
   incoming and outgoing connections are different things. Your module or your
   network must do the authentication.

4. **A blocking socket call uses no fuel.** This is point 4 above, but more
   dangerous: a module that waits in `sock_recv` does no work. The `timeout` in
   the grant limits one call, not a series of calls. So a module that
   reconnects in a loop can wait forever, one timeout at a time. Use a worker
   with a timeout for any code you do not trust.

5. **The number of sockets is limited, the bandwidth is not.** `max_sockets`
   limits how many sockets an instance holds at the same time. Nothing limits
   how much it sends through them, how fast it opens and closes them, or how
   many instances you run.

6. **Resolving a name gives no permission.** `resolve => allow` lets a module
   send questions to your resolver. This is a kind of outgoing access: it
   reaches your DNS servers, and they see the names it asks for. But it cannot
   extend a `connect` grant, because grants name addresses, and `sock_connect`
   checks the address it receives.

7. **The socket extension is not part of the specification.** Preview 1
   defines four socket calls. Every other call a client needs is a WasmEdge
   extension, under the same module name. WasmEdge decides its data layouts.
   They are implemented from WasmEdge's headers, and they can change there.
   See [wasi.md](wasi.md).

## Run untrusted code

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),
{ok, W}   = wasm_instance_worker:start_link(Mod, #{limits => wasm_limits:untrusted(),
                                          isolation => fresh,
                                          imports => MinimalImports}),
{ok, R}   = wasm_instance_worker:call(W, ~"handle", [Req], 500).
```

Check all five before you ship it:

- `isolation => fresh`, so no state survives a request
- a timeout that kills the worker, not one that only stops waiting for it
- the smallest import set that does the job
- `wasm_engine:set_page_limit/1` set for the node
- a bounded pool, so concurrency is capped

## Reporting

Found something? Open an issue marked security, or contact the maintainer
directly.

## The compiled tier's artifact cache is executable code

`code_cache_dir` holds generated BEAM modules. To use one, the runtime calls
`code:load_binary/3` on bytes from a file. **Anyone who can write into that
directory can run code in your node.** Protect it exactly as you protect the
release itself. This is why the cache is off unless you set it.

What the runtime checks before it will use one:

- the path is absolute, with no `.` or `..`
- the directory is owned by the node's user and has no group or other write bit
- every directory above it is owned by root or by that user, and has no group
  or other write bit either. A parent directory owned by someone else can
  replace what is below it, whatever the mode of the cache directory itself
- nothing on the path is a symlink, and an entry is a regular file
- the entry's own checksum matches, before any byte of it is loaded

Every failure is a cache miss and a line in the log. Nothing raises. A cache
that cannot be trusted only makes the node slower, never broken.

**What this does not do.** The checksum detects damage (a partial write, a bad
disk, a crash). It does **not** detect a writer who puts a well-formed entry
there. Also, checking the path and then opening a file in it are two separate
steps, so the path can change between them. Neither gap is closed, and with
this model neither needs to be. When every parent directory is owned by root
or by the node's user, and nobody else can write to it, only those two users
can change where the path leads. Both of them can already run code in the
node. The checks catch configuration mistakes (a cache under `/tmp`, a
directory that someone else can rename). They do not stop an attacker who is
already inside.

If you need to trust files written by someone who may **not** run code in
your node, this is not enough. You would need to authenticate the files, and
this runtime does not do that.

## Read this next

[WASI](wasi.md), for the capabilities you grant.
