-module(wasm_memory).
-moduledoc """
Linear memory backed by chunked `atomics` arrays.

You reach this through `wasm:read_memory/3` and `wasm:write_memory/3`; read the
module itself when you want to know what a store costs you. The representation
is the one the benchmarks chose. Per store, on this machine:

```
  atomics, raw 64-bit word        6.1 ns
  atomics, masked i32 store      22.1 ns
  ETS, one row per word          41.6 ns
  ETS, 4 KB chunk rebuild       278   ns
  binary rebuild, 64 KiB       1201   ns
```

Binaries are immutable, so every store rebuilds the whole page. At 1.2 us per
store they are unusable as mutable memory however good they are at reads.
`atomics` is mutable in place, and it is an OTP built-in resource rather than
a NIF this project ships, so linear memory needs no native code of its own to
be viable. That is the single biggest reason a pure-Erlang runtime is
practical at all.

**Chunking.** Memory is a tuple of `atomics` arrays, one per 1 MiB, so
`memory.grow` appends a chunk instead of reallocating and copying. A single
flat array would make growth O(size), and growing to 64 MiB one page at a
time would copy about a thousand times more than it allocates.

**Alignment.** `atomics` granularity is 64 bits, so an aligned i64 store
is one `put` while an i32 store is a read-modify-write. Accesses that span
two words take a slower path again. The value is assembled little-endian
because that is what WebAssembly specifies, independent of host byte order.

**Accounting.** `atomics` memory is off-heap and invisible to `max_heap_size`,
so every page is reserved before it is allocated. Without that, a module could
exhaust your node without its owning process's heap ever growing. Reserving,
growing and releasing are `wasm_keeper` transactions, which is also what records
who holds the memory and releases it when they are all gone.
""".

-include("wasm.hrl").

-export([new/1, new/2, new_shared/1, create/2, size_pages/1, size_bytes/1,
         limits/1, free/1, acquire/3, release/2, resource/1]).
-export([is_mem/1]).
-export([load/3, store/4]).
-export([atomic_load/3, atomic_store/4, atomic_rmw/5, atomic_cmpxchg/5]).
-export([is_shared/1, id/1]).
-export([load_bytes/3, store_bytes/3]).
-export([field_indices/0, mask/1]).
-export([grow/2, fill/4, copy/4, copy/5, init/5]).
-export([to_binary/1]).

%% 1 MiB per chunk: 16 pages, 131072 atomic words.
-define(CHUNK_BITS, 20).
-define(PAGE_SIZE_SHIFT, 16).      % 64 KiB
-define(CHUNK_BYTES, (1 bsl ?CHUNK_BITS)).
-define(CHUNK_WORDS, (?CHUNK_BYTES div 8)).
-define(PAGES_PER_CHUNK, (?CHUNK_BYTES div ?PAGE_SIZE)).

-record(mem, {
    %% This memory's identity in the holder registry, minted by `wasm_keeper'
    %% before the arrays exist so that reserving the pages and recording who
    %% they belong to are one step. Also what the wait queue is keyed by: it is
    %% created once per memory and copied into every handle on it.
    id        :: wasm_keeper:resource(),
    chunks    :: tuple(),                   % of atomics:atomics_ref()
    pages = 0 :: non_neg_integer(),         % current size in 64 KiB pages
    %% Set only for a memory another instance can observe, which is to say one
    %% that is imported or exported. Growth has to be visible through every
    %% handle, and the handle is an immutable record, so the page count for
    %% those lives in an `atomics' cell instead.
    %%
    %% Private memories keep `undefined' here and read the field above. That
    %% matters: the count is read on *every* access, and an `atomics:get'
    %% measured 6.0 ns against 1.9 ns for a record field.
    pages_ref :: undefined | atomics:atomics_ref(),
    %% Companion to `pages_ref'. Chunks are `atomics' arrays and so are already
    %% shared by reference; it is the *tuple* holding them that is per-record,
    %% so a holder that has not grown does not know about a chunk another
    %% holder added. This cell publishes the current tuple.
    chunks_ref :: undefined | reference(),
    max       :: undefined | non_neg_integer(),
    %% Declared `shared' by the module, which is the threads proposal's sense:
    %% more than one agent may reach it, so `memory.atomic.wait' is allowed.
    %% Distinct from `pages_ref', which marks a memory another *instance* can
    %% observe growing and is set for anything imported or exported.
    shared = false :: boolean(),
    %% The index type this memory is addressed by. It is not used on the access
    %% path (the width is resolved into each instruction when the IR is built),
    %% only when an importer checks that the memory it was handed matches what
    %% it declared.
    index_type = i32 :: i32 | i64,
    %% log2 of this memory's chunk size. Sized to the memory rather than fixed
    %% globally: a fixed 1 MiB chunk made a module declaring one 64 KiB page
    %% cost 1 MiB, a 16x over-allocation that dominated the per-instance
    %% footprint (1080 KB against 11 KB of process). Address decoding is still
    %% a shift and a mask, just against this value instead of a constant.
    shift     :: pos_integer(),
    %% The holder token this *handle* may remove, and the only thing `free/1'
    %% acting on it can do.
    %%
    %% `none' for a memory an instance created or imported: the instance holds
    %% the token, and `free/1' on a handle obtained through `wasm:extern/2'
    %% must not release memory that instance is still using. A standalone
    %% memory holds a `{process, Pid}' token, which its creator's exit also
    %% removes. A standalone *thread-shared* memory holds a `manual' token,
    %% which nothing but `free/1' removes: it exists to be used by agents other
    %% than the one that made it, so its creator exiting must not take it away.
    token     :: wasm_keeper:token() | none
}).

-opaque mem() :: #mem{}.
-export_type([mem/0]).

%%% ------------------------------------------------------------ lifecycle ---

-doc """
A standalone memory, held by the calling process.

Observable, because a standalone memory exists to be handed to instances: two
of them importing it must see each other grow it, and a handle is an immutable
record that cannot learn a new size on its own. Only a memory an instance
defined and neither imports nor exports keeps its size in the handle, which is
the case the fast path was measured for.
""".
-spec new(non_neg_integer() | #limits{}) -> {ok, mem()} | {error, term()}.
new(Pages) when is_integer(Pages) -> new(#limits{min = Pages});
new(#limits{} = Limits) -> create(Limits, #{observable => true}).

-spec new(non_neg_integer(), undefined | non_neg_integer()) ->
          {ok, mem()} | {error, term()}.
new(Pages, Max) -> new(#limits{min = Pages, max = Max}).

-doc """
A memory whose size is visible to other instances.

Used for a memory that is imported or exported: growing it through one handle
has to be seen through all of them, and the handle is an immutable record.
""".
-spec new_shared(#limits{}) -> {ok, mem()} | {error, term()}.
new_shared(Limits) -> create(Limits, #{observable => true}).

%% A thread-shared memory is grown by whichever agent gets there first and the
%% proposal makes that visible to all of them, so its size can never live in
%% one agent's handle.
observable(#{observable := true}, _Shared) -> true;
observable(_Opts, Shared) -> Shared.

-doc """
Create a memory, saying who holds it and whether its size is observable.

`observable` is the linking sense: another instance can see this memory grow, so
its size and chunk tuple are published rather than kept in the handle. `holder`
is a `{Token, Owner}` pair naming the registry entry to create and the process
whose death removes it; leave it out and the memory belongs to the calling
process, or to nobody at all if it is thread-shared.
""".
-spec create(#limits{}, map()) -> {ok, mem()} | {error, term()}.
create(#limits{min = Pages, max = Max, index_type = IdxType, shared = Shared},
       Opts) ->
    {Token, Owner} = maps:get(holder, Opts, default_holder(Shared)),
    %% A caller that named the holder holds it. The handle then carries no
    %% removable token, so `free/1' on a handle taken out with `wasm:extern/2'
    %% cannot release a memory the instance is still running on.
    Held = case maps:is_key(holder, Opts) of true -> none; false -> Token end,
    %% Both cells are made before the reservation, so the registry row can name
    %% them from the start: a memory whose pages were charged but whose
    %% published cell nothing knew about would leak that cell for good.
    {CRef, PagesRef} =
        case observable(Opts, Shared) of
            true -> {make_ref(), atomics:new(1, [{signed, false}])};
            false -> {undefined, undefined}
        end,
    case wasm_keeper:reserve(Pages, {memory, CRef, PagesRef}, Token, Owner) of
        {error, Why} ->
            {error, page_error(Why)};
        {ok, Res} ->
            try
                Shift = chunk_shift(Pages),
                NChunks = chunks_for(Pages, Shift),
                Chunks = list_to_tuple([new_chunk(Shift)
                                        || _ <- lists:seq(1, NChunks)]),
                PagesRef =:= undefined orelse atomics:put(PagesRef, 1, Pages),
                CRef =:= undefined orelse wasm_engine:cell_put(CRef, Chunks),
                {ok, #mem{id = Res, chunks = Chunks, pages = Pages, max = Max,
                          index_type = IdxType, shift = Shift, token = Held,
                          pages_ref = PagesRef, chunks_ref = CRef,
                          shared = Shared}}
            catch
                %% The reservation is already recorded, and the caller may well
                %% catch what running out of `atomics' arrays throws. Dying is
                %% handled by the keeper's monitor; surviving is not.
                Class:Reason:Stack ->
                    ok = wasm_keeper:release(Res, Token),
                    erlang:raise(Class, Reason, Stack)
            end
    end.

%% A thread-shared memory is made to be handed to other agents, so it is held
%% manually and released only by `free/1'. Anything else belongs to whoever
%% made it.
default_holder(true) -> {manual, none};
default_holder(false) -> {{process, self()}, self()}.

page_error(limit) -> page_limit;
page_error(instance_limit) -> instance_limit;
%% The keeper is supervised and restarted, so this is a resource refusal for as
%% long as that takes rather than a fault. `memory.grow' has to see a value it
%% can turn into -1 either way.
page_error(keeper_unavailable) -> page_limit.

%% Chunk size is the memory's initial size, clamped to between one page and
%% 1 MiB and rounded up to a power of two so decoding stays a shift.
%%
%% Small memories stop paying for large ones, and large memories keep a chunk
%% big enough that growth does not build an unreasonably long chunk tuple.
chunk_shift(Pages) ->
    Bytes = erlang:max(Pages * ?PAGE_SIZE, ?PAGE_SIZE),
    Clamped = erlang:min(Bytes, ?CHUNK_BYTES),
    round_up_shift(?PAGE_SIZE_SHIFT, Clamped).

round_up_shift(Shift, Target) when (1 bsl Shift) >= Target -> Shift;
round_up_shift(Shift, Target) -> round_up_shift(Shift + 1, Target).

%% `atomics' arrays start zeroed, which is exactly the specified initial state
%% of linear memory.
new_chunk(Shift) -> atomics:new((1 bsl Shift) div 8, [{signed, false}]).

chunks_for(0, _Shift) -> 0;
chunks_for(Pages, Shift) ->
    ChunkBytes = 1 bsl Shift,
    ((Pages * ?PAGE_SIZE) + ChunkBytes - 1) div ChunkBytes.

-doc """
Release this handle's claim on the memory.

Idempotent, and safe to call on a handle that holds no claim: a memory an
instance created or imported is released by destroying that instance, so
`free/1` on a handle you got from `wasm:extern/2` does nothing rather than
pulling the memory out from under it.

The pages that go back are the size the memory is *now*, taken from the
registry, not the size this handle was made at. A grown memory used to return
only its original pages and leave the rest charged for the life of the node.
""".
-spec free(mem()) -> ok.
free(#mem{token = none}) -> ok;
free(#mem{id = Res, token = Token}) -> wasm_keeper:release(Res, Token).

-doc """
Add a holder to this memory, for an instance importing it.

`{error, gone}` means the last holder released it first, which has to be a link
failure rather than a memory the importer goes on to use.
""".
-spec acquire(mem(), wasm_keeper:token(), pid() | none) ->
          ok | {error, gone | instance_limit | keeper_unavailable}.
acquire(#mem{id = Res}, Token, Owner) -> wasm_keeper:acquire(Res, Token, Owner).

-doc "Remove a named holder, whatever this handle's own token is.".
-spec release(mem(), wasm_keeper:token()) -> ok.
release(#mem{id = Res}, Token) -> wasm_keeper:release(Res, Token).

-doc "This memory's registry identity.".
-spec resource(mem()) -> wasm_keeper:resource().
resource(#mem{id = Res}) -> Res.

%% Inlined: this is read on every access, and the private clause has to stay a
%% record match rather than becoming a call.
-compile({inline, [size_pages/1, chunk/2, mask/1, mask_bits/1,
                   word/2, put_word/3, check_bounds/3, read/3, write/4]}).

-spec size_pages(mem()) -> non_neg_integer().
size_pages(#mem{pages_ref = undefined, pages = P}) -> P;
size_pages(#mem{pages_ref = Ref}) -> atomics:get(Ref, 1).

-spec size_bytes(mem()) -> non_neg_integer().
size_bytes(M) -> size_pages(M) * ?PAGE_SIZE.

-doc """
Whether a term is a memory handle.

Needed because an embedder hands over bare terms: a module importing a memory
may be given a table, a function or a number, and that has to come back as a
link error rather than as a `function_clause` from inside the runtime.
""".
-spec is_mem(term()) -> boolean().
is_mem(#mem{}) -> true;
is_mem(_) -> false.

-spec limits(mem()) -> #limits{}.
limits(#mem{max = M, index_type = T, shared = Shared} = Mem) ->
    #limits{min = size_pages(Mem), max = M, index_type = T, shared = Shared}.

%%% ----------------------------------------------------------------- grow ---

-doc """
Grow by `Delta` pages, returning the previous size.

Returns `{error, _}` rather than trapping: `memory.grow` is specified to
push -1 on failure, so refusal is a value the module observes, not a fault.

Growth is serialised per memory, in two stages. The keeper validates the
request against the *authoritative* size, reserves the budget and hands out the
right to grow; the caller allocates the chunks, which is the expensive half and
so must not happen inside the serialised callback; the keeper then publishes
the chunk tuple and the new size together.

Two agents growing one shared memory used to each build a tuple from its own
view and publish both cells independently, so one could publish a size backed
by the other's shorter tuple. A single compare-and-exchange cannot fix that,
because there are two cells to move.
""".
-spec grow(mem(), non_neg_integer()) ->
          {ok, non_neg_integer(), mem()} | {error, term()}.
grow(#mem{id = Res, max = Max, index_type = IdxType} = M, Delta) ->
    %% The address space a 64-bit memory may occupy is far larger, though in
    %% practice the node-wide page budget refuses long before either ceiling.
    Space = case IdxType of i32 -> ?MAX_PAGES_32; i64 -> ?MAX_PAGES_64 end,
    Declared = case Max of undefined -> Space; _ -> Max end,
    Ceiling = erlang:min(Declared, Space),
    case wasm_keeper:grow_begin(Res, Delta, Ceiling) of
        {error, exceeds_max} when Declared >= Space ->
            {error, exceeds_address_space};
        {error, Why} ->
            {error, grow_error(Why)};
        {ok, GrowRef, Pages} ->
            New = Pages + Delta,
            try extend(M, Pages, New) of
                Chunks ->
                    ok = wasm_keeper:grow_commit(Res, GrowRef, Chunks, New),
                    {ok, Pages, M#mem{chunks = Chunks, pages = New}}
            catch
                %% Dying here is handled by the keeper's monitor. Surviving a
                %% failure is not, so the growth has to be given back or every
                %% later grower on this memory queues behind one that ended.
                Class:Reason:Stack ->
                    ok = wasm_keeper:grow_abort(Res, GrowRef),
                    erlang:raise(Class, Reason, Stack)
            end
    end.

grow_error(limit) -> page_limit;
%% Refused because a holder would pass its own ceiling, which `memory.grow'
%% turns into -1 exactly as it does a node budget refusal.
grow_error(instance_limit) -> instance_limit;
grow_error(keeper_unavailable) -> page_limit;
grow_error(Why) -> Why.

%% Built against the published tuple rather than this handle's, because the
%% size the keeper just authorised may include chunks another holder added.
extend(#mem{shift = Shift} = M, _Pages, New) ->
    Current = current_chunks(M),
    Have = tuple_size(Current),
    Need = chunks_for(New, Shift),
    Extra = [new_chunk(Shift) || _ <- lists:seq(1, erlang:max(0, Need - Have))],
    list_to_tuple(tuple_to_list(Current) ++ Extra).

current_chunks(#mem{chunks_ref = undefined, chunks = Chunks}) -> Chunks;
current_chunks(#mem{chunks_ref = Ref}) -> wasm_engine:cell_get(Ref).

%%% ------------------------------------------------------- loads and stores ---

-doc """
Load `Nbytes` at `Addr` as an unsigned little-endian integer.

Bounds are checked against the whole access, and the addition is done in
Erlang's arbitrary-precision integers, so an offset near 2^32 cannot wrap
around into a valid address the way it would in C.
""".
-spec load(mem(), non_neg_integer(), 1..8) -> non_neg_integer().
load(M, Addr, Nbytes) ->
    Pages = size_pages(M),
    check_bounds(Addr, Nbytes, Pages),
    read(M, Addr, Nbytes).

-spec store(mem(), non_neg_integer(), 1..8, integer()) -> ok.
store(M, Addr, Nbytes, Value) ->
    Pages = size_pages(M),
    check_bounds(Addr, Nbytes, Pages),
    write(M, Addr, Nbytes, Value band mask(Nbytes)).

-doc """
Atomic access.

An atomic load or store is naturally aligned, which validation enforces
exactly, so it never straddles two of the 64-bit words the memory is made of.
That makes a load one `atomics:get` and an aligned eight-byte store one
`atomics:put`.

Anything narrower is a *part* of a word, so writing it means reading the word,
replacing a field and writing it back. That is three operations and another
process can write the same word between them, so it goes through
`atomics:compare_exchange` and retries. A read-modify-write is the same loop
with the arithmetic inside it, which is what makes `i32.atomic.rmw.add` a
single indivisible step rather than a load and a store that usually work.
""".
-spec atomic_load(mem(), non_neg_integer(), 1..8) -> non_neg_integer().
atomic_load(M, Addr, Nbytes) ->
    check_atomic(M, Addr, Nbytes),
    read(M, Addr, Nbytes).

-spec atomic_store(mem(), non_neg_integer(), 1..8, integer()) -> ok.
atomic_store(M, Addr, 8, Value) when Addr band 7 =:= 0 ->
    check_atomic(M, Addr, 8),
    put_word(M, Addr, Value);
atomic_store(M, Addr, Nbytes, Value) ->
    check_atomic(M, Addr, Nbytes),
    _ = update_word(M, Addr, Nbytes, fun(_Old) -> Value band mask(Nbytes) end),
    ok.

-doc "Apply `Fun` to the value at `Addr` indivisibly, answering the old value.".
-spec atomic_rmw(mem(), non_neg_integer(), 1..8, atom(), integer()) ->
          non_neg_integer().
atomic_rmw(M, Addr, Nbytes, Op, Operand) ->
    check_atomic(M, Addr, Nbytes),
    update_word(M, Addr, Nbytes,
                fun(Old) -> rmw_apply(Op, Old, Operand, Nbytes) end).

-doc """
Replace the value at `Addr` only if it is `Expected`, answering what was there.

The answer is the old value either way, so a caller compares it with what it
expected to find out whether the exchange happened. That is the specified
interface, and it is why this cannot be built from a load and a store.
""".
-spec atomic_cmpxchg(mem(), non_neg_integer(), 1..8, integer(), integer()) ->
          non_neg_integer().
atomic_cmpxchg(M, Addr, Nbytes, Expected, Replacement) ->
    check_atomic(M, Addr, Nbytes),
    Want = Expected band mask(Nbytes),
    update_word(M, Addr, Nbytes,
                fun(Old) when Old =:= Want -> Replacement band mask(Nbytes);
                   (Old) -> Old
                end).

rmw_apply(add, Old, X, N) -> (Old + X) band mask(N);
rmw_apply(sub, Old, X, N) -> (Old - X) band mask(N);
rmw_apply('and', Old, X, N) -> (Old band X) band mask(N);
rmw_apply('or', Old, X, N) -> (Old bor X) band mask(N);
rmw_apply('xor', Old, X, N) -> (Old bxor X) band mask(N);
rmw_apply(xchg, _Old, X, N) -> X band mask(N).

%% Replace one field of a word, retrying until no other writer intervened.
%% Answers the field's previous value.
update_word(M, Addr, Nbytes, Fun) ->
    Base = Addr band (bnot 7),
    Shift = (Addr band 7) * 8,
    Mask = mask(Nbytes) bsl Shift,
    cas_loop(M, Base, Shift, Mask, Nbytes, Fun).

cas_loop(M, Base, Shift, Mask, Nbytes, Fun) ->
    Word = word(M, Base),
    Old = (Word bsr Shift) band mask(Nbytes),
    New = Fun(Old),
    Updated = (Word band (bnot Mask)) bor ((New band mask(Nbytes)) bsl Shift),
    case Updated =:= Word of
        %% Nothing to write. Skipping the exchange is not just an optimisation:
        %% a `cmpxchg' that did not match must not count as a write.
        true -> Old;
        false ->
            case cas_word(M, Base, Word, Updated) of
                ok -> Old;
                _Changed -> cas_loop(M, Base, Shift, Mask, Nbytes, Fun)
            end
    end.

cas_word(#mem{shift = Shift} = M, Addr, Expected, Desired) ->
    Chunk = chunk(M, Addr bsr Shift),
    Ix = ((Addr band ((1 bsl Shift) - 1)) bsr 3) + 1,
    atomics:compare_exchange(Chunk, Ix, Expected,
                             Desired band 16#FFFFFFFFFFFFFFFF).

%% Atomic accesses are bounds-checked like any other, and additionally must be
%% naturally aligned. Validation rejects a mis-declared alignment, but the
%% *address* is a run-time value, so an unaligned one traps here.
check_atomic(M, Addr, Nbytes) ->
    check_bounds(Addr, Nbytes, size_pages(M)),
    case Addr band (Nbytes - 1) of
        0 -> ok;
        _ -> wasm_error:trap(unaligned_atomic,
                             #{addr => Addr, size => Nbytes})
    end.

-doc """
A stable identity for this memory, for keying the wait queue.

Two handles on the same shared memory must agree, and a private memory must not
collide with anyone. The registry identity is both: minted once per memory and
copied into every handle on it.
""".
-spec id(mem()) -> term().
id(#mem{id = Id}) -> Id.

-doc "Whether this memory was declared shared, which `wait` requires.".
-spec is_shared(mem()) -> boolean().
is_shared(#mem{shared = S}) -> S.

check_bounds(Addr, Nbytes, Pages) ->
    case Addr >= 0 andalso Addr + Nbytes =< Pages * ?PAGE_SIZE of
        true -> ok;
        false -> wasm_error:trap(out_of_bounds_memory_access,
                                 #{addr => Addr, size => Nbytes,
                                   limit => Pages * ?PAGE_SIZE})
    end.

%% An 8-byte access that is 8-byte aligned is a single `atomics:get', the 6 ns
%% case. Everything else assembles from one or two words.
read(M, Addr, 8) when Addr band 7 =:= 0 ->
    word(M, Addr);
read(M, Addr, Nbytes) ->
    Shift = (Addr band 7) * 8,
    Base = Addr band (bnot 7),
    Low = word(M, Base) bsr Shift,
    Bits = Nbytes * 8,
    case Shift + Bits =< 64 of
        true ->
            Low band mask(Nbytes);
        false ->
            %% The access straddles two words; take the remainder from the next.
            High = word(M, Base + 8),
            ((High bsl (64 - Shift)) bor Low) band mask(Nbytes)
    end.

write(M, Addr, 8, Value) when Addr band 7 =:= 0 ->
    put_word(M, Addr, Value);
write(M, Addr, Nbytes, Value) ->
    Shift = (Addr band 7) * 8,
    Base = Addr band (bnot 7),
    Bits = Nbytes * 8,
    case Shift + Bits =< 64 of
        true ->
            Old = word(M, Base),
            Keep = bnot (mask(Nbytes) bsl Shift),
            put_word(M, Base, (Old band Keep) bor (Value bsl Shift));
        false ->
            LowBits = 64 - Shift, OldLow = word(M, Base),
            put_word(M, Base,
                     (OldLow band mask_bits(Shift)) bor
                     ((Value band mask_bits(LowBits)) bsl Shift)),
            HighBits = Bits - LowBits, OldHigh = word(M, Base + 8),
            put_word(M, Base + 8,
                     (OldHigh band (bnot mask_bits(HighBits))) bor
                     (Value bsr LowBits))
    end.

fill_run(_C, _I, _W, 0) -> ok;
fill_run(C, I, W, N) ->
    atomics:put(C, I, W),
    fill_run(C, I + 1, W, N - 1).

%% Address decoding: chunk index, then word index inside the chunk. Both are
%% shifts and masks because the chunk size is a power of two.
word(#mem{shift = Shift} = M, Addr) ->
    Chunk = chunk(M, Addr bsr Shift),
    atomics:get(Chunk, ((Addr band ((1 bsl Shift) - 1)) bsr 3) + 1).

put_word(#mem{shift = Shift} = M, Addr, Value) ->
    Chunk = chunk(M, Addr bsr Shift),
    atomics:put(Chunk, ((Addr band ((1 bsl Shift) - 1)) bsr 3) + 1,
                Value band 16#FFFFFFFFFFFFFFFF).

%% The fast path is a bounds test against the tuple this holder already has,
%% which is every access to a private memory and every access to a shared one
%% below the size it was last seen at. The slow path is reached only by reading
%% into territory another holder grew, and refreshes from the published tuple.
chunk(#mem{chunks = Chunks}, Idx) when Idx < tuple_size(Chunks) ->
    element(Idx + 1, Chunks);
chunk(#mem{chunks_ref = Ref}, Idx) when Ref =/= undefined ->
    element(Idx + 1, wasm_engine:cell_get(Ref)).

-doc """
The all-ones mask for an access of `N` bytes.

Exported because `wasm_core` needs it at *generation* time to build the same
mask into compiled code, and one table of widths is the point: see
`wasm_exec:load_spec/1`, which is read the same way and for the same reason.
""".
-spec mask(pos_integer()) -> non_neg_integer().
mask(1) -> 16#FF;
mask(2) -> 16#FFFF;
mask(4) -> 16#FFFFFFFF;
mask(8) -> 16#FFFFFFFFFFFFFFFF;
mask(N) -> (1 bsl (N * 8)) - 1.

mask_bits(64) -> 16#FFFFFFFFFFFFFFFF;
mask_bits(N) -> (1 bsl N) - 1.

%%% ----------------------------------------------------------- bulk access ---

-doc """
Read a byte range as a binary, for host functions and WASI.

Costs roughly a nanosecond per byte because the bytes have to be assembled
from atomic words. This is the operation that would most benefit from the
optional native backend, where it becomes a single memcpy.
""".
-spec load_bytes(mem(), non_neg_integer(), non_neg_integer()) -> binary().
load_bytes(M, Addr, Len) ->
    Pages = size_pages(M),
    check_bounds(Addr, Len, Pages),
    collect(M, Addr, Len, <<>>).

%% Accumulates into a binary rather than a list of small binaries. The runtime
%% over-allocates on `<<Acc/binary, ...>>' append, so this grows in amortised
%% constant time; building 8192 heap binaries and then joining them measured
%% roughly eight times slower.
collect(_M, _Addr, 0, Acc) -> Acc;
collect(M, Addr, Len, Acc) when Len >= 8, Addr band 7 =:= 0 ->
    collect(M, Addr + 8, Len - 8, <<Acc/binary, (word(M, Addr)):64/little>>);
collect(M, Addr, Len, Acc) ->
    collect(M, Addr + 1, Len - 1, <<Acc/binary, (read(M, Addr, 1)):8>>).

-spec store_bytes(mem(), non_neg_integer(), binary()) -> ok.
store_bytes(M, Addr, Bin) ->
    Pages = size_pages(M),
    check_bounds(Addr, byte_size(Bin), Pages),
    scatter(M, Addr, Bin).

scatter(_M, _Addr, <<>>) -> ok;
scatter(M, Addr, <<W:64/little, Rest/binary>>) when Addr band 7 =:= 0 ->
    put_word(M, Addr, W),
    scatter(M, Addr + 8, Rest);
scatter(M, Addr, <<B:8, Rest/binary>>) ->
    write(M, Addr, 1, B),
    scatter(M, Addr + 1, Rest).

-doc """
Whole-memory snapshot. Diagnostics and tests only: it materialises the
entire memory as a binary.
""".
-spec to_binary(mem()) -> binary().
to_binary(M) -> load_bytes(M, 0, size_pages(M) * ?PAGE_SIZE).

%%% ----------------------------------------------------------- bulk memory ---

%% `memory.fill' and `memory.copy' check bounds before writing anything, so a
%% partially-completed operation is never observable after a trap.
-spec fill(mem(), non_neg_integer(), byte(), non_neg_integer()) -> ok.
%% Bounds come from `size_pages/1', not from the handle's own field. A holder
%% that has not itself grown a shared memory carries a stale count, and
%% checking against that trapped on addresses another agent had already made
%% valid.
fill(M, Addr, Byte, Len) ->
    check_bounds(Addr, Len, size_pages(M)),
    fill_at(M, Addr, Byte, Len).

fill_at(_M, _Addr, _Byte, 0) -> ok;
fill_at(M, Addr, Byte, Len) ->
    W = word_of_byte(Byte),
    fill_loop(M, Addr, W, Byte, Len).

fill_loop(_M, _Addr, _W, _B, 0) -> ok;
fill_loop(M, Addr, W, B, Len) when Len >= 8, Addr band 7 =:= 0 ->
    %% As `copy_run/5': one chunk resolution per run rather than per word.
    N = run_words(M, Len, [Addr]),
    {C, I} = word_at(M, Addr),
    ok = fill_run(C, I, W, N),
    fill_loop(M, Addr + N * 8, W, B, Len - N * 8);
fill_loop(M, Addr, W, B, Len) ->
    write(M, Addr, 1, B),
    fill_loop(M, Addr + 1, W, B, Len - 1).

word_of_byte(B) ->
    X = B band 16#FF,
    X * 16#0101010101010101.

%% Overlapping ranges copy backwards, matching memmove semantics, which the
%% specification requires.
-spec copy(mem(), non_neg_integer(), non_neg_integer(), non_neg_integer()) -> ok.
copy(M, Dst, Src, Len) ->
    Pages = size_pages(M),
    case Dst + Len > Pages * ?PAGE_SIZE orelse Src + Len > Pages * ?PAGE_SIZE of
        true -> wasm_error:trap(out_of_bounds_memory_access,
                                #{dst => Dst, src => Src, size => Len,
                                  limit => Pages * ?PAGE_SIZE});
        false -> copy_at(M, Dst, Src, Len)
    end.

copy_at(_M, _Dst, _Src, 0) -> ok;
%% Backward copy is only needed when the ranges actually overlap with the
%% destination above the source. Testing `Dst =< Src' alone sent every
%% high-to-low copy down the byte-at-a-time path even when the ranges were
%% disjoint, which measured 0.01 GB/s against 0.4 GB/s for the word path: a
%% 40x penalty on the common case of copying between two separate buffers.
copy_at(M, Dst, Src, Len) when Dst =< Src; Dst >= Src + Len ->
    copy_fwd(M, Dst, Src, Len);
copy_at(M, Dst, Src, Len) ->
    copy_bwd(M, Dst + Len - 1, Src + Len - 1, Len).

-doc """
Copy between two distinct memories.

There is no overlap to worry about, so the source range is read out as one
binary and written back as one binary. Both ranges are bounds-checked before
anything is written, which is what the specification requires: a `memory.copy`
that traps must leave the destination untouched.

**A zero-length copy is checked too.** Returning early on `Len = 0` looks
harmless and is not: the specification admits an address exactly at the end of
a memory and requires a trap one byte beyond it, whatever the length. The
same-memory `copy/4` above already checks before it looks at the length, and
`memory_copy1.wast` asserts both directions.
""".
-spec copy(mem(), non_neg_integer(), mem(), non_neg_integer(),
           non_neg_integer()) -> ok.
copy(DstMem, Dst, SrcMem, Src, Len) ->
    check_bounds(Dst, Len, size_pages(DstMem)),
    check_bounds(Src, Len, size_pages(SrcMem)),
    copy_across(DstMem, Dst, SrcMem, Src, Len).

copy_across(_DstMem, _Dst, _SrcMem, _Src, 0) -> ok;
copy_across(DstMem, Dst, SrcMem, Src, Len) ->
    store_bytes(DstMem, Dst, load_bytes(SrcMem, Src, Len)).

copy_fwd(_M, _D, _S, 0) -> ok;
copy_fwd(M, D, S, Len) when Len >= 8, D band 7 =:= 0, S band 7 =:= 0 ->
    N = run_words(M, Len, [D, S]),
    {DC, DI} = word_at(M, D),
    {SC, SI} = word_at(M, S),
    ok = copy_run(DC, DI, SC, SI, N),
    copy_fwd(M, D + N * 8, S + N * 8, Len - N * 8);
copy_fwd(M, D, S, Len) ->
    write(M, D, 1, read(M, S, 1)),
    copy_fwd(M, D + 1, S + 1, Len - 1).

%% Aligned words moved without resolving the address again.
%%
%% This loop called `word/2' and `put_word/3' per eight bytes, and each of those
%% recomputes the chunk, the shift and the word index from the address. The
%% chunk changes only when a run crosses one, so it is resolved once per run and
%% the index is stepped. Two `atomics' operations per word is what the
%% representation costs and is the floor underneath this.
%%
%% Ascending, which is what makes it safe for the overlapping case `copy_at/4'
%% sends here: the destination is at or below the source.
copy_run(_DC, _DI, _SC, _SI, 0) -> ok;
copy_run(DC, DI, SC, SI, N) ->
    %% No mask on the way in: the value came from an unsigned array and is
    %% already a 64-bit word.
    atomics:put(DC, DI, atomics:get(SC, SI)),
    copy_run(DC, DI + 1, SC, SI + 1, N - 1).

%% The chunk holding `Addr' and the index of its word inside that chunk.
word_at(#mem{shift = Shift} = M, Addr) ->
    {chunk(M, Addr bsr Shift),
     ((Addr band ((1 bsl Shift) - 1)) bsr 3) + 1}.

%% How many aligned words can be moved before any of `Addrs' leaves its chunk,
%% and no more than `Len' allows.
run_words(#mem{shift = Shift}, Len, Addrs) ->
    PerChunk = (1 bsl Shift) bsr 3,
    lists:min([Len bsr 3
               | [PerChunk - ((A band ((1 bsl Shift) - 1)) bsr 3) || A <- Addrs]]).

copy_bwd(_M, _D, _S, 0) -> ok;
copy_bwd(M, D, S, Len) ->
    write(M, D, 1, read(M, S, 1)),
    copy_bwd(M, D - 1, S - 1, Len - 1).

-doc "`memory.init`: copy from a passive data segment.".
-spec init(mem(), non_neg_integer(), binary(), non_neg_integer(),
           non_neg_integer()) -> ok.
init(M, Dst, Segment, SrcOff, Len) ->
    Pages = size_pages(M),
    case SrcOff + Len =< byte_size(Segment)
         andalso Dst + Len =< Pages * ?PAGE_SIZE of
        false -> wasm_error:trap(out_of_bounds_memory_access,
                                 #{dst => Dst, src => SrcOff, size => Len});
        true ->
            <<_:SrcOff/binary, Slice:Len/binary, _/binary>> = Segment,
            store_bytes(M, Dst, Slice)
    end.

-doc """
Where each field of a memory handle lives, by index.

Generated code reads a handle directly rather than calling in for every access,
so it needs these, and a header of literals that silently disagreed with the
record would corrupt memory rather than fail. `wasm_core_SUITE` asserts this
answer equals `include/wasm_memory.hrl`, so adding a field breaks a test.
""".
-spec field_indices() -> #{atom() => pos_integer()}.
field_indices() ->
    #{chunks => #mem.chunks, pages => #mem.pages, pages_ref => #mem.pages_ref,
      chunks_ref => #mem.chunks_ref, shift => #mem.shift,
      size => record_info(size, mem)}.
