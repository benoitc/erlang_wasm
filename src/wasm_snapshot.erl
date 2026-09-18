-module(wasm_snapshot).
-moduledoc """
Initialized runtime snapshots: an immutable copy of an already-started guest.

Captured after a runtime's `init()` has returned and while no call is running,
and restored into a **fresh instance** at that point, so interpreter startup is
skipped and one-instance-per-request isolation is kept exactly as it was.

Call it an initialized runtime snapshot or an instance snapshot, and not a heap
snapshot: `wasm_heap` here already means the garbage-collected object store,
which is a narrower thing and is in fact one of the states a snapshot refuses
to carry.

## What it holds

Every linear memory's bytes, size and limits; mutable globals; table contents;
and the dropped data and element segment sets. Nothing else, and the omissions
are the design:

**Ownership metadata is exactly what must not be captured.** Keeper resource
ids, holder tokens, owner pids and live handles are identities of *this*
instance in *this* node at *this* moment, and an image carrying them would
restore into references to something already destroyed. Restore mints fresh
ones, reserving through `wasm_keeper` as instantiation does. What enters the
image is only what can be reconstructed from it.

**Host and operating-system resources are reconstructed per request**, never
serialised: open files and directories, sockets, clocks, random providers,
Erlang closures and processes, and whatever state an arbitrary host import
maintains. The caller builds those fresh for each restore.

## What it refuses

Loudly, and never half-applied:

| | why |
| --- | --- |
| an instance with no retained module handle | provenance cannot be proved |
| an imported memory, table or global | the aliasing an image cannot represent |
| a shared memory | the same, plus another thread may be writing it |
| a non-empty `wasm_heap` | references are ids into a store, not values |
| an external `funcref` or any `externref` | it names an instance that is not this one |

The first is the one that is easy to get wrong. An `identity` is a *name* and
`wasm:compile/2` lets a caller supply one, so loading module A under hash `H`
and compiling a different B with `identity => {sha256, H}` gives B a claim on
`H` that succeeds. A claim proves the cache holds *something* under that name,
never that this instance came from it, so `#inst.module_handle` is retained at
instantiation and capture requires it.

## Restore does not run the start function

Ordinary instantiation always does, and a start function is arbitrary guest
code with arbitrary host effects: running it during a restore would repeat,
against fresh imports, work the captured image already contains. This is the
single most important sentence here.
""".

-export([capture/3, restore/4, info/1, bytes/1, module_of/1]).
-export([owner/1, with_owner/2]).
-export([to_parts/1, from_parts/2, logical_bytes/1]).

-include("wasm.hrl").
-include("wasm_exec.hrl").

%% Deliberately not a map: a snapshot is matched on, and a record gives the
%% compiler something to check when a field is added later.
-record(snapshot, {
          id            :: reference(),
          handle        :: wasm_module_cache:handle(),
          version       :: binary(),
          key           :: term(),
          source        :: reference(),
          globals       :: tuple(),
          %% The **contents**, not the handles. A table is a handle exactly as
          %% a memory is, and capturing `#mut.tables` captured the source
          %% instance's tables: a restored instance then called through a table
          %% that had been freed with the instance it belonged to. Calling
          %% through the table is what caught it; comparing the tuples would
          %% have looked perfectly correct.
          tables        :: [[term()]],
          mems          :: [captured_mem()],
          dropped_elems :: map(),
          dropped_datas :: map(),
          %% What each import module's hook said to keep, by module name.
          hooks         :: #{binary() => portable()},
          bytes         :: non_neg_integer(),
          %% The process that holds this image's claim on its module and its
          %% share of the byte budget, and that knows who still wants it. An
          %% image is an Erlang term and the BEAM will collect it, but a term
          %% cannot say "I am gone", and two things have to be given back when
          %% it is.
          owner         :: undefined | pid()
         }).

-doc """
What a hook may keep: no pid, port, reference or fun.

Restricted by construction *and* checked at capture, because a hook free to
return any term could quietly contradict the promise that host resources are
never captured.
""".
-type portable() :: binary() | number() | atom() | [portable()]
                  | tuple() | #{portable() => portable()}.

-type captured_mem() :: #{pages := non_neg_integer(),
                          runs := [{non_neg_integer(), binary()}]}.

-doc "An immutable image. Copyable between processes; see `wasm:acquire/1`.".
%% `portable/0` and `captured_mem/0` go out with `snapshot/0` because the
%% nominal below is over `#snapshot{}`, whose fields are typed with them: a
%% reader of the public type needs them visible, and ex_doc says so if they are
%% not. The comment belongs here rather than above the `-export_type', where
%% edoc would read it as that attribute's doc comment and exit.
-nominal snapshot() :: #snapshot{}.

-export_type([snapshot/0, portable/0, captured_mem/0]).

%%% -------------------------------------------------------------- capture ---

-doc """
Capture, given the module the instance was built from.

The caller resolves the handle rather than this module doing it, which keeps
`wasm_snapshot` out of the `wasm` and `wasm_module_cache` cycle:
`wasm_architecture_SUITE` documents exactly three, and a fourth member is a
change to the architecture rather than a detail.
""".
-spec capture(#inst{}, wasm_module_cache:handle(), map()) ->
          {ok, snapshot()} | {error, wasm_error:error()}.
capture(#inst{} = Inst, Handle, Opts) ->
    M = maps:get(module, Opts),
    eligible_then_capture(Inst, M, Handle, maps:remove(module, Opts)).

eligible_then_capture(Inst, M, Handle, Opts) ->
    case eligible(Inst, M) of
        {error, _} = E -> E;
        ok             -> do_capture(Inst, M, Handle, Opts)
    end.

%% Every refusal, checked before anything is copied so a rejection costs
%% nothing.
eligible(Inst, M) ->
    Checks = [fun() -> every_import_answers(Inst, M) end,
              fun() -> no_imported_state(M) end,
              fun() -> no_shared_memory(Inst) end,
              fun() -> empty_heap(Inst) end,
              fun() -> only_own_refs(Inst) end],
    lists:foldl(fun(_C, {error, _} = E) -> E;
                   (C, ok) -> C()
                end, ok, Checks).

%% **Silence means no.** A module in `bindings` with no entry in
%% `snapshot_hooks` refuses the capture, which is the only default that stays
%% correct when somebody adds a stateful import later and forgets this page. A
%% module holding nothing says `stateless` and means it.
every_import_answers(Inst, #module{imports = Imports}) ->
    Hooks = wasm_instance:snapshot_hooks(Inst),
    case [Mod || Mod <- import_modules(Imports), not maps:is_key(Mod, Hooks)] of
        [] -> ok;
        [Mod | _] ->
            refuse(import_not_snapshottable,
                   ~"this import module declares no snapshot hook",
                   #{import => Mod})
    end.

import_modules(Imports) ->
    lists:usort([Mod || #import{module = Mod} <- Imports]).

%% An imported memory, table or global aliases something another instance also
%% holds, and an image has no way to represent that: restoring would either
%% duplicate the state or silently share whatever the new imports happen to be.
no_imported_state(#module{imports = Imports}) ->
    case [D || #import{desc = D} <- Imports, is_state(D)] of
        [] -> ok;
        [D | _] ->
            refuse(imported_state_not_snapshottable,
                   ~"an imported memory, table or global cannot be captured",
                   #{import => element(1, D)})
    end.

is_state({mem, _})    -> true;
is_state({table, _})  -> true;
is_state({global, _}) -> true;
is_state(_)           -> false.

no_shared_memory(Inst) ->
    #mut{mems = Mems} = wasm_instance:mut(Inst),
    case [Mem || Mem <- tuple_to_list(Mems), wasm_memory:is_shared(Mem)] of
        [] -> ok;
        _  -> refuse(shared_memory_not_snapshottable,
                     ~"a shared memory cannot be captured", #{})
    end.

%% References are ids into a store, and the store is not in the image. A module
%% that never allocated has no heap at all, which is the case this supports.
empty_heap(#inst{heap = undefined}) -> ok;
empty_heap(#inst{heap = Heap}) ->
    case wasm_heap:size(Heap) of
        0 -> ok;
        N -> refuse(heap_not_snapshottable,
                    ~"a non-empty object store cannot be captured",
                    #{objects => N})
    end.

%% A `funcref' carries the instance it came from, and reading one whose
%% instance is gone traps. Self-references are relocated on restore; anything
%% else names something the image cannot speak for.
only_own_refs(#inst{id = Id} = Inst) ->
    #mut{globals = Gs0, tables = Ts} = wasm_instance:mut(Inst),
    %% The **values**, because those are what `do_capture/4` keeps. Checking
    %% the raw tuple would refuse every module that exports a mutable global,
    %% since that is a cell rather than a value.
    Gs = deref(Gs0),
    Values = tuple_to_list(Gs) ++ lists:append(contents(Ts)),
    case [V || V <- Values, not admissible(V, Id)] of
        [] -> ok;
        [V | _] ->
            refuse(foreign_reference_not_snapshottable,
                   ~"this value cannot be captured",
                   %% The shape, never the value: what is being refused here is
                   %% precisely a term with no meaning outside this node, and
                   %% putting it in an error is how it escapes anyway.
                   #{shape => shape_of(V)})
    end.

shape_of(T) when is_tuple(T), tuple_size(T) > 0 -> element(1, T);
shape_of(T) when is_tuple(T)  -> empty_tuple;
shape_of(T) when is_pid(T)    -> pid;
shape_of(T) when is_port(T)   -> port;
shape_of(T) when is_reference(T) -> reference;
shape_of(T) when is_function(T) -> function;
shape_of(T) when is_binary(T) -> binary;
shape_of(T) when is_atom(T)   -> T;
shape_of(T) when is_list(T)   -> list;
shape_of(T) when is_map(T)    -> map;
shape_of(_)                   -> other.

%% **An allowlist, not a list of things to refuse**, and the difference is why
%% this is written out. The refusal it replaced named `{externref, _}`, a term
%% nothing in `src/` constructs: a real external reference is `{extern, V}`
%% (`wasm_exec:789`) or a bare host term, since `heap_of/2` ends in
%% `heap_of(_, _St) -> extern`. So the catch-all admitted a pid into an image.
%% Adding a clause for `{extern, _}` would be the same mistake one address
%% along, because the next shape anyone adds falls through the same default.
%% Enumerating what may be captured refuses them all by construction.
admissible(V, _Id) when is_integer(V); is_float(V) -> true;
%% `wasm_num` keeps what an Erlang float cannot: the infinities as atoms and a
%% NaN with its payload bits.
admissible(infinity, _Id)           -> true;
admissible(neg_infinity, _Id)       -> true;
admissible({nan, _, _}, _Id)        -> true;
admissible(null, _Id)               -> true;
admissible({i31, V}, _Id)           -> is_integer(V);
%% A v128 lane vector.
admissible(B, _Id) when is_binary(B) -> byte_size(B) =:= 16;
%% Its own, and naming a function by index. A reference to another instance is
%% refused by `only_own_refs/1`'s error rather than silently carried.
admissible({funcref, Id, F}, Id)    -> is_integer(F);
admissible(_, _)                    -> false.

%% Each hook is asked twice: whether this instance is eligible at all, and then
%% what to keep. Whatever it keeps is **validated**, because a hook free to
%% return any term could quietly put a pid, a port, a reference or a fun into an
%% image and contradict the promise that host resources are never captured.
run_hooks(Inst, M) ->
    Hooks = wasm_instance:snapshot_hooks(Inst),
    lists:foldl(
      fun(_Mod, {error, _} = E) ->
              E;
         (Mod, {ok, Acc}) ->
              case maps:get(Mod, Hooks) of
                  stateless ->
                      {ok, Acc};
                  #{eligible := Eligible, capture := Capture} ->
                      run_hook(Inst, Mod, Eligible, Capture, Acc)
              end
      end, {ok, #{}}, import_modules(M#module.imports)).

run_hook(Inst, Mod, Eligible, Capture, Acc) ->
    case Eligible(Inst) of
        {error, E} ->
            {error, E};
        ok ->
            case Capture(Inst) of
                {error, E} ->
                    {error, E};
                {ok, Kept} ->
                    case portable(Kept) of
                        true  -> {ok, Acc#{Mod => Kept}};
                        false -> refuse(hook_capture_not_portable,
                                        ~"a hook kept something unportable",
                                        #{import => Mod})
                    end
            end
    end.

%% Restricted on purpose, and checked rather than trusted: no pid, port,
%% reference or fun may enter an image, because every one of them means
%% something only in this node at this moment.
portable(B) when is_binary(B) -> true;
portable(N) when is_number(N) -> true;
portable(A) when is_atom(A) -> true;
portable(L) when is_list(L) -> lists:all(fun portable/1, L);
portable(T) when is_tuple(T) -> portable(tuple_to_list(T));
portable(M) when is_map(M) ->
    portable(maps:keys(M)) andalso portable(maps:values(M));
portable(_) -> false.

do_capture(Inst, M, Handle, Opts) ->
    #mut{globals = Gs0, tables = Ts, mems = Mems,
         dropped_elems = DE, dropped_datas = DD} = wasm_instance:mut(Inst),
    %% **Values, not cells.** A mutable global the module exports is a
    %% `wasm_global` cell rather than a slot (`wasm_instance:932-934`), so
    %% capturing the tuple raw captured the *source instance's* cells: two
    %% restores then shared one global, and destroying the initialisation
    %% instance took the cell with it. Exactly the defect the `tables` field
    %% above records having fixed, left unfixed here.
    Gs = deref(Gs0),
    Captured = [capture_mem(Mem) || Mem <- tuple_to_list(Mems)],
    Tables = contents(Ts),
    %% What is **retained**, which is what the budget charges and what
    %% `snapshot_info/1` has always answered. Keeping runs rather than whole
    %% memories drops it by about 9x on a real interpreter, so a node with
    %% `max_snapshot_bytes` set admits proportionally more images.
    Bytes = lists:sum([byte_size(R) || C <- Captured,
                                       {_, R} <- maps:get(runs, C)]),
    %% **No owner yet.** Holding an image's claim means calling the module
    %% cache, and the cache calls `wasm:compile/2` on a miss, so anything
    %% long-lived that holds one is inside the facade's cycle. `wasm` attaches
    %% an owner with `with_owner/2`, which keeps this module -- the mechanism,
    %% what a capture copies and a restore lays over -- out of it entirely.
    case run_hooks(Inst, M) of
        {error, _} = HookError -> HookError;
        {ok, Kept} -> captured(Inst, Handle, Opts, Gs, Tables, Captured,
                               DE, DD, Bytes, Kept)
    end.

captured(Inst, Handle, Opts, Gs, Tables, Captured, DE, DD, Bytes, Kept) ->
    {ok, #snapshot{id = make_ref(), handle = Handle,
                   version = maps:get(version, Opts, ~"1"),
                   key = maps:get(compatibility_key, Opts, undefined),
                   source = Inst#inst.id,
                   globals = Gs, tables = Tables, mems = Captured,
                   dropped_elems = DE, dropped_datas = DD, hooks = Kept,
                   bytes = Bytes, owner = undefined}}.

deref(Globals) ->
    list_to_tuple([case wasm_global:is_global(G) of
                       true  -> wasm_global:get(G);
                       false -> G
                   end || G <- tuple_to_list(Globals)]).

%% Every table's elements, in order. `wasm_table:to_list/1` is the only thing
%% that crosses from a handle to values.
contents(Tables) ->
    [wasm_table:to_list(T) || T <- tuple_to_list(Tables)].

%% Reconstructible properties only: size, limits, and the bytes. Not the
%% resource id, not the holder, not the owner.
%% **Runs, not the whole memory.** A started interpreter is mostly zero --
%% CPython's image is 41.9 MB and 88.5% of it is zero -- so keeping one flat
%% binary kept 37 MB of nothing and wrote it back on every restore.
%%
%% `limits` is gone with it: nothing read it, and it was an Erlang record, so
%% dropping it means an image holds no positional tuple over `wasm.hrl`.
capture_mem(Mem) ->
    Pages = wasm_memory:size_pages(Mem),
    #{pages => Pages,
      runs => runs(wasm_memory:to_binary(Mem))}.

%% Aligned **down** to 8 for the offset and **up** to 8 for the length, so a
%% write lands on `wasm_memory`'s word path rather than its read-modify-write
%% head and tail. Widening a run can only include bytes that were zero, which
%% the fill would have written anyway.
-define(ALIGN, 8).

runs(Bin) -> runs(Bin, 0, byte_size(Bin), []).

runs(_Bin, Off, Size, Acc) when Off >= Size ->
    lists:reverse(Acc);
runs(Bin, Off, Size, Acc) ->
    case nonzero_from(Bin, Off, Size) of
        none ->
            lists:reverse(Acc);
        Start0 ->
            Start = Start0 - (Start0 rem ?ALIGN),
            End0 = zero_from(Bin, Start0, Size),
            End = min(Size, End0 + ((?ALIGN - (End0 rem ?ALIGN)) rem ?ALIGN)),
            Len = End - Start,
            <<_:Start/binary, Run:Len/binary, _/binary>> = Bin,
            runs(Bin, End, Size, [{Start, Run} | Acc])
    end.

%% The first non-zero byte at or after `Off`, found by asking the binary
%% module for the next zero-free stretch rather than walking bytes.
nonzero_from(Bin, Off, Size) when Off < Size ->
    Len = Size - Off,
    <<_:Off/binary, Tail:Len/binary>> = Bin,
    case count_zeros(Tail, 0) of
        N when Off + N >= Size -> none;
        N                      -> Off + N
    end;
nonzero_from(_Bin, _Off, _Size) ->
    none.

count_zeros(<<0, R/binary>>, N) -> count_zeros(R, N + 1);
count_zeros(_, N)               -> N.

%% Where the non-zero stretch starting at `Off` ends. A short zero gap inside
%% one is not worth splitting a run for: a second `store_bytes/3` costs more
%% than carrying a few zero bytes along inside the first.
%%
%% The rationale used to count a fill as well, and there is no fill any more:
%% a restore writes the runs onto memory that is already zero. What is left is
%% the straight trade of one more call against up to 63 more bytes written, and
%% 64 is still on the right side of it. Lowering it would shrink an image and
%% lengthen its run list, which is a capture-side question and not this one.
-define(MIN_GAP, 64).

zero_from(Bin, Off, Size) when Off < Size ->
    Len = Size - Off,
    <<_:Off/binary, Tail:Len/binary>> = Bin,
    case run_end(Tail, 0) of
        N -> Off + N
    end;
zero_from(_Bin, Off, _Size) ->
    Off.

run_end(Bin, N) ->
    case Bin of
        <<_:N/binary, Rest/binary>> when Rest =/= <<>> ->
            case count_zeros(Rest, 0) of
                0 -> run_end(Bin, N + 1);
                Z when Z >= ?MIN_GAP -> N;
                Z -> run_end(Bin, N + Z)
            end;
        _ ->
            N
    end.

%%% -------------------------------------------------------------- restore ---

-doc """
Build a fresh instance at the captured point.

**The caller does not supply the module.** It comes from the handle the image
retained, which is why this takes a snapshot rather than being an option to
`instantiate/3`. That option reopened the forgery on the other side: capture
module A under `H`, then restore with an inline module B built with
`identity => {sha256, H}` and a matching key, and the image is laid over a
different module's layout. Taking the module from the image closes it by
construction, because there is no argument left to forge.
""".
-spec restore(snapshot(), #module{}, map(), map()) ->
          {ok, #inst{}} | {error, wasm_error:error()}
        | {error, wasm_error:error(), #inst{}}.
restore(#snapshot{handle = Handle, key = Key} = S, M, Bindings, Opts) ->
    case maps:get(compatibility_key, Opts, undefined) of
        Key ->
            %% `wasm_instance:new/3' and **not** `wasm:instantiate/3`: the
            %% latter runs the start function, which is arbitrary guest code
            %% with arbitrary host effects, and the image already contains
            %% whatever it did.
            %% `segments => false`: every byte an active segment would write
            %% is overwritten by the image below, and the memory underneath is
            %% zero from `atomics:new/2`. Applying them would cost this restore
            %% twice, once to write and once to fill back to zero, which was
            %% 54% of a CPython restore. `wasm_instance` still makes their
            %% bounds decision, so a module that could not be instantiated is
            %% refused here exactly as it was.
            case wasm_instance:new(M, Bindings,
                                   maps:remove(compatibility_key,
                                               Opts#{module_handle => Handle,
                                                     segments => false})) of
                {error, _} = E -> E;
                {ok, Inst}     -> lay_over(S, Inst)
            end;
        Other ->
            %% Checked before anything is copied, so a mismatch costs nothing.
            refuse(snapshot_incompatible,
                   ~"the compatibility key does not match the image",
                   #{expected => Key, got => Other})
    end.

lay_over(#snapshot{} = S, Inst) ->
    case wasm_error:capture(fun() -> do_lay_over(S, Inst) end) of
        {ok, ok} ->
            {ok, Inst};
        {error, E} ->
            %% A restore that fails at any point destroys what it had built and
            %% gives back what it had reserved. The half-built instance goes to
            %% the caller to be destroyed **in full**: releasing the state table
            %% here would leave this instance's claims on its memories, tables
            %% and globals held, and a full teardown belongs to `wasm`, which
            %% calling from here would put the mechanism in the facade's cycle.
            {error, E, Inst}
    end.

%% The **new** instance's hooks, not the image's: imports are reconstructed per
%% restore, and a hook restores only the guest-visible state its module owns.
restore_hooks(#snapshot{hooks = Kept}, Inst) ->
    Hooks = wasm_instance:snapshot_hooks(Inst),
    %% A hook that fails fails the restore, carrying **its own** error rather
    %% than a raise flattened into `internal`. `lay_over/2` then releases the
    %% half-built instance, so nothing escapes either way.
    maps:fold(
      fun(_Mod, _Capture, {error, _} = E) ->
              E;
         (Mod, Capture, {ok, ok}) ->
              case maps:get(Mod, Hooks, stateless) of
                  stateless          -> {ok, ok};
                  #{restore := Rest} -> hook_restored(Rest(Inst, Capture))
              end
      end, {ok, ok}, Kept).

hook_restored(ok)             -> {ok, ok};
hook_restored({error, _} = E) -> E.

do_lay_over(#snapshot{source = From} = S, #inst{id = To} = Inst) ->
    #mut{mems = Mems, tables = Tables} = Current = wasm_instance:mut(Inst),
    Restored = restore_mems(tuple_to_list(Mems), S#snapshot.mems),
    %% Into the **fresh** instance's own tables, element by element. The
    %% handles stay the ones instantiation made; only what they hold comes
    %% from the image.
    ok = restore_tables(tuple_to_list(Tables), S#snapshot.tables, From, To),
    %% Into the fresh instance's **own** cells where it has them, exactly as
    %% the tables go into its own tables. Writing the image's tuple over
    %% `#mut.globals` would replace a cell this instance owns with a value,
    %% and an exported global would stop being reachable through
    %% `wasm:extern/2`.
    Globals = restore_globals(element(#mut.globals, Current),
                              relocate(S#snapshot.globals, From, To)),
    ok = wasm_instance:set_mut(
           Inst, Current#mut{mems = list_to_tuple(Restored),
                             globals = Globals,
                             dropped_elems = S#snapshot.dropped_elems,
                             dropped_datas = S#snapshot.dropped_datas}),
    restore_hooks(S, Inst).

restore_globals(Fresh, Captured) ->
    list_to_tuple(
      [case wasm_global:is_global(G) of
           true  -> ok = wasm_global:set(G, V), G;
           false -> V
       end || {G, V} <- lists:zip(tuple_to_list(Fresh), tuple_to_list(Captured))]).

restore_tables([], [], _From, _To) ->
    ok;
restore_tables([T | Ts], [Elems | Es], From, To) ->
    %% Grown to fit, as memories already were. A guest that calls `table.grow`
    %% during `init()` captured fine and then could not be restored, because
    %% the fresh instance's table is at the module's declared minimum.
    %% `wasm_table:grow/3` is what respects the ceiling; `array:set` would not,
    %% since `wasm_table:89` creates the array `{fixed, false}` and extending
    %% it silently would walk past every limit `grow/3` enforces.
    ok = fit(T, wasm_table:size(T), length(Elems)),
    %% **One store, not one per element.** `wasm_table:set/3` writes the whole
    %% array back and bumps a version each time, so a thousand-entry table was
    %% a thousand whole-array writes. `init/3` folds and stores once, which is
    %% what `wasm_instance` already does for element segments.
    ok = wasm_table:init(T, 0, [reloc(V, From, To) || V <- Elems]),
    restore_tables(Ts, Es, From, To).

lay_runs(_Mem, []) ->
    ok;
lay_runs(Mem, [{Off, Run} | Rest]) ->
    ok = wasm_memory:store_bytes(Mem, Off, Run),
    lay_runs(Mem, Rest).

fit(_T, Have, Want) when Have >= Want ->
    ok;
fit(T, Have, Want) ->
    case wasm_table:grow(T, Want - Have, null) of
        {ok, _} -> ok;
        {error, Why} -> erlang:error({snapshot_restore_table_grow_failed, Why})
    end.

restore_mems([], []) ->
    [];
restore_mems([Mem | Ms], [#{pages := Pages, runs := Runs} | Cs]) ->
    Have = wasm_memory:size_pages(Mem),
    %% The fresh instance's memory is at the module's declared minimum, and the
    %% image may have grown past it. A refusal here is the node's page budget
    %% speaking, and it has to fail the restore rather than leave the image
    %% laid over a memory too small to hold it.
    %% `grow/2` answers a **new** record carrying the new chunks and size, and
    %% writing through the old one used the pre-grow page count. For a memory
    %% that is neither imported nor exported that count lives in the record
    %% rather than an atomics cell (`wasm_memory:275`), so the write tripped
    %% `check_bounds`. It survived only because reactors export their memory.
    Grown = case Have >= Pages of
                true ->
                    Mem;
                false ->
                    case wasm_memory:grow(Mem, Pages - Have) of
                        {ok, _, New} -> New;
                        {error, Why} ->
                            erlang:error({snapshot_restore_grow_failed, Why})
                    end
            end,
    %% **Only the runs are written, and the gaps are left alone.** Two things
    %% have to hold for that and each is enforced by something: `atomics:new/2`
    %% hands back zeroed memory, and `restore/4` asks `wasm_instance:new/3` not
    %% to apply the active data segments that would otherwise have dirtied it.
    %% `runs/1` captures every non-zero byte, aligned outward, so a memory that
    %% starts at zero and receives the runs **is** the image.
    %%
    %% The gaps were filled until this was measured, and they had to be while
    %% the segments were being applied: 25.2 ms of a 46.5 ms CPython restore
    %% went on zeroing memory that was already zero. A guest whose image is
    %% dense pays far less for it -- QuickJS's is 53.7% non-zero against
    %% CPython's 17.7% -- which is why it looked small on the guest the restore
    %% path was first measured on.
    ok = lay_runs(Grown, Runs),
    %% The grown handle goes **back into `#mut.mems`**, not just written
    %% through. An observable memory keeps its size in an atomics cell, so the
    %% old record would still read the new size; an unexported one keeps it in
    %% the record, and the instance would go on believing the pre-grow size and
    %% trap on the first access past it.
    [Grown | restore_mems(Ms, Cs)].

%% A `funcref' names the instance it came from, and a restored one has a new
%% identity, so every self-reference is rewritten. **In globals as well as
%% tables**: a suite comparing only memories would not catch a global holding
%% one.
relocate(Tuple, From, To) ->
    list_to_tuple([reloc(V, From, To) || V <- tuple_to_list(Tuple)]).

reloc({funcref, From, F}, From, To) -> {funcref, To, F};
reloc(V, _From, _To)                -> V.

%%% ----------------------------------------------------------------- info ---

-doc "Attach the process that holds this image's claim and its charge.".
-spec with_owner(snapshot(), pid()) -> snapshot().
with_owner(#snapshot{} = S, Owner) when is_pid(Owner) -> S#snapshot{owner = Owner}.

-doc "The process holding this image, or `undefined` before one is attached.".
-spec owner(snapshot()) -> undefined | pid().
owner(#snapshot{owner = Owner}) -> Owner.

-doc "Size, module and version, so a size has a way to be read.".
-spec info(snapshot()) -> #{bytes := non_neg_integer(),
                            module := wasm_module_cache:handle(),
                            version := binary()}.
info(#snapshot{bytes = B, handle = H, version = V}) ->
    #{bytes => B, module => H, version => V}.

-spec bytes(snapshot()) -> non_neg_integer().
bytes(#snapshot{bytes = B}) -> B.

-spec module_of(snapshot()) -> wasm_module_cache:handle().
module_of(#snapshot{handle = H}) -> H.

refuse(Kind, Msg, Ctx) ->
    {error, #{class => invalid, kind => Kind, msg => Msg, ctx => Ctx}}.

%%% ------------------------------------------------------------ on disk ---

-doc """
An image's contents, in the plain shape `wasm_snapshot_file` encodes.

**Self-references are normalised.** A `funcref` names its defining instance by
a `reference()`, which means nothing outside this node and nothing after a
restart, so every one is rewritten to the atom `self` on the way out and back
to a fresh identity on the way in. That is the same relocation `reloc/3` does
between two live instances, carried across a file.
""".
-spec to_parts(snapshot()) -> wasm_snapshot_file:parts().
to_parts(#snapshot{handle = {wasm_module, Hash}, source = Src} = S) ->
    #{hash => Hash,
      version => S#snapshot.version,
      key => S#snapshot.key,
      shape => shape(S),
      globals => [reloc(V, Src, self) || V <- tuple_to_list(S#snapshot.globals)],
      tables => [[reloc(V, Src, self) || V <- T] || T <- S#snapshot.tables],
      mems => S#snapshot.mems,
      dropped => {S#snapshot.dropped_elems, S#snapshot.dropped_datas},
      hooks => S#snapshot.hooks}.

%% Cheap, and it turns every mismatch between an image and a module from a
%% `function_clause` somewhere inside a restore into a refusal by name.
shape(#snapshot{globals = Gs, tables = Ts, mems = Ms}) ->
    {tuple_size(Gs), [length(T) || T <- Ts], [maps:get(pages, M) || M <- Ms]}.

-doc """
An image from what a file held, bound to a module the caller resolved.

The caller supplies the handle rather than the file naming one it trusts: a
planted image would otherwise pick whichever resident module suits it, which is
the forgery `restore/3` closes on the live path by taking the module from the
image. Off disk the direction inverts, so the **caller** decides which module
an image is for and this refuses one that does not match.
""".
-spec from_parts(wasm_snapshot_file:parts(), wasm_module_cache:handle()) ->
          {ok, snapshot()} | {error, wasm_error:error()}.
from_parts(#{hash := Hash} = P, {wasm_module, Want} = Handle) ->
    case Hash of
        Want -> built(P, Handle);
        _    -> refuse(snapshot_wrong_module,
                       ~"this image was captured from another module",
                       #{expected => Want, found => Hash})
    end.

built(P, Handle) ->
    #{version := V, key := K, globals := Gs, tables := Ts, mems := Ms,
      dropped := {DE, DD}, hooks := Hooks} = P,
    %% A fresh identity per load, so two images read from the same file are as
    %% distinct as two captured in this node would be.
    Src = make_ref(),
    Bytes = lists:sum([byte_size(R) || M <- Ms, {_, R} <- maps:get(runs, M)]),
    {ok, #snapshot{id = make_ref(), handle = Handle, version = V, key = K,
                   source = Src,
                   globals = list_to_tuple([reloc(G, self, Src) || G <- Gs]),
                   tables = [[reloc(E, self, Src) || E <- T] || T <- Ts],
                   mems = Ms, dropped_elems = DE, dropped_datas = DD,
                   hooks = Hooks, bytes = Bytes, owner = undefined}}.

-doc """
The address space an image covers, as against the `bytes` it retains.

`bytes` is what the budget charges and what an image holds; this is what a
restore will write into. They differ by about 6x on a started CPython, and a
decompression ceiling has to come from the second.
""".
-spec logical_bytes(snapshot()) -> non_neg_integer().
logical_bytes(#snapshot{mems = Ms}) ->
    lists:sum([maps:get(pages, M) * 65536 || M <- Ms]).
