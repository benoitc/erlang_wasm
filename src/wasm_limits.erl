-module(wasm_limits).
-moduledoc """
Resource limits, and an honest account of what they do not cover.

Pass a limits map to `wasm:instantiate/3`, or per call. Reach for the presets
when you have not measured anything yet: getting these right matters most for
the people least likely to tune them.

```
Limits = wasm_limits:untrusted(),
{ok, Inst} = wasm:instantiate(Module, Imports, Limits).
```

## What you get

| limit | bounds |
| --- | --- |
| `fuel` | execution budget, charged at calls and loop back-edges; every unbounded execution passes through one of those |
| `timeout` | wall clock per call. Enforced by whoever owns the instance, not by the library: an inline call runs in your process and cannot be interrupted. See `docs/worker.md` |
| `max_depth` | WebAssembly call depth |
| `max_heap_words` | Erlang heap ceiling, applied by the process owning the instance, killing runaway term allocation |
| `max_memory_pages` | every memory this instance can reach, added together |
| node page budget | `wasm_engine`, across all instances |

`max_memory_pages` bounds what an instance can *reach*, not what it created. An
imported memory counts, because a module that imports one can address every
page of it, and it counts once however many import slots name it. Growing a
memory two instances share therefore needs room under both ceilings: the
stricter one wins, or the more generous instance would grow a memory past what
the other was promised. Refusal is the value -1 from `memory.grow`, as the
specification requires, and an instance that cannot fit its declared memory at
all fails to instantiate.

## What putting it in a process does not give you

This section exists because "each instance is in a process, so it is isolated"
is the most tempting wrong claim available about this design. A process is a
*fault and lifecycle* boundary. It is not a security boundary, and these gaps
are real:

- **Linear memory is invisible to `max_heap_size`.** `atomics` arrays are
  off-heap. A module can exhaust node memory without its process heap moving at
  all. This is why page accounting is explicit and node-wide in `wasm_engine`
  rather than left to the BEAM.
- **Per-instance limits do not bound concurrency.** No single instance can
  monopolise a scheduler, because the interpreter is preemptible. But ten
  thousand instances each behaving perfectly will still saturate every
  scheduler. To bound that you need a pool or a concurrency cap above this
  layer; a per-instance limit cannot see it.
- **The atom table is node-wide and never reclaimed.** One reachable
  `binary_to_atom` on anything a guest controls would be a permanent leak and
  eventually a node kill, immune to every limit here. That covers the module
  bytes and the strings a guest passes across the WASI boundary, and
  `wasm_prop_SUITE` asserts both: not that the count never moves, since host
  libraries intern atoms when they lazily load a module, but that it does not
  grow with the number of distinct strings a guest sends.
- **Host functions are the real attack surface.** Limits constrain WebAssembly,
  not the Erlang code you supply as an import. A host function that reads a
  file, allocates without bound, or blocks forever is outside all of this.
  Capability-based WASI (`wasi_preview1`) is how the standard ones get
  addressed; imports you write yourself are yours to bound.
- **Timing and microarchitectural side channels are not addressed.** Nothing
  here prevents a co-tenant module from measuring shared cache behaviour. A
  shared BEAM node is not a boundary against that class of attack; only
  OS-level or hardware separation is.
- **`fuel` bounds work, not time.** A host call that blocks consumes no fuel.
  Wall-clock bounding is `timeout`, and you need the two together.
""".

-export([untrusted/0, trusted/0, default/0, merge/2, validate/1]).

-type limits() :: #{atom() => term()}.
-export_type([limits/0]).

-doc """
Defaults for running code you do not control.

Deliberately tight. If you need more, raise the specific limit knowingly. That
is a better failure mode than discovering a permissive default was
load-bearing.
""".
-spec untrusted() -> limits().
untrusted() ->
    #{fuel             => 10_000_000,
      timeout          => 1_000,
      max_depth        => 256,
      max_heap_words   => 8 * 1024 * 1024,     % ~64 MiB of terms
      max_memory_pages => 256,                 % 16 MiB of linear memory
      max_host_calls   => 10_000}.

-doc """
Defaults for your own code. No fuel ceiling, no timeout.

Faults still come back as values. Nothing here is unsafe, only unbounded.
""".
-spec trusted() -> limits().
trusted() ->
    #{fuel      => infinity,
      timeout   => infinity,
      max_depth => 8192}.

-spec default() -> limits().
default() -> untrusted().

-spec merge(limits(), limits()) -> limits().
merge(Base, Override) -> maps:merge(Base, Override).

-doc "Check a limits map, and reject one that cannot mean what it says.".
-spec validate(limits()) -> ok | {error, term()}.
validate(Limits) ->
    Checks =
        [{fuel, fun(V) -> V =:= infinity orelse (is_integer(V) andalso V > 0) end},
         {timeout, fun(V) -> V =:= infinity orelse (is_integer(V) andalso V > 0) end},
         {max_depth, fun(V) -> is_integer(V) andalso V > 0 end},
         {max_memory_pages,
          fun(V) -> V =:= infinity orelse (is_integer(V) andalso V >= 0) end},
         {max_host_calls,
          fun(V) -> V =:= infinity orelse (is_integer(V) andalso V >= 0) end},
         {max_heap_words, fun(V) -> is_integer(V) andalso V > 0 end}],
    Bad = [K || {K, Pred} <- Checks, maps:is_key(K, Limits),
                not Pred(maps:get(K, Limits))],
    case Bad of
        [] -> ok;
        _ -> {error, {invalid_limits, Bad}}
    end.
