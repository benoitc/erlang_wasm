-module(wasm).
-moduledoc """
A WebAssembly runtime for Erlang/OTP.

Start here when you are embedding the runtime. You load a module once,
instantiate it as often as you need, call its exports, and destroy the instances
when you are done.

```erlang
{ok, Mod}  = wasm:load(Binary),                  % compiled once, cached
{ok, Inst} = wasm:instantiate(Mod, Imports),     % owned by this process
{ok, [R]}  = wasm:call(Inst, ~"run", [42]),
ok         = wasm:destroy(Inst).
```

## You get one execution path

Create an instance, call it, destroy it. That is the *inline* path and there is
no other. The library ships no process wrapper, because process architecture
belongs to your application; `ets`, `counters` and `atomics` do not impose one
either.

Build actors *on* this API rather than beside it. A worker is a process that
calls `instantiate/3` in its `init` and `call/3` in its `handle_call`. See
`docs/worker.md` and `examples/wasm_worker.erl` for the pattern, including
per-request isolation, timeouts, and killing runaway code.

## You own the instance

An instance belongs to the process that created it and stays valid while that
process lives, like a port or an ETS table. You may pass it to another process,
but do not call the same instance from two processes at once: both
read-modify-write the same mutable state and the last writer wins. Putting the
instance inside a process is what serialises the calls.

Pages are released when the owner exits, however it exits, so forgetting
`destroy/1` is untidy rather than a leak. Destroying an instance releases only
*its* claim on each memory: one it imported stays as long as anybody else holds
it, and destroying the same instance twice releases nothing the second time.

## Every failure is a value

Nothing here raises, including on hostile input. A malformed binary, an
ill-typed module, a trap and a resource limit all come back as `{error, E}`,
where `E` carries the class (`malformed`, `invalid`, `link`, `trap`,
`exhaustion`), a machine-readable kind, the specification's message text, and
context to diagnose it.
""".


-include("wasm.hrl").
-include("wasm_exec.hrl").

-export([load/1, load/2, load_file/1, unload/1]).
-export([compile/1, compile/2, validate/1, instantiate/2, instantiate/3, destroy/1]).
-export([call/3, call/4, get_global/2, exports/1, extern/2]).
-export([pin/2, release/2, release_all/1]).
-export([read_memory/3, write_memory/3, memory_size/1]).
-export([format_error/1]).

-export_type([module_/0, instance/0]).

-doc "A module: compiled inline, or a handle to a cached one.".
-nominal module_() :: #module{} | wasm_module_cache:handle().
-doc "An instance, owned by the process that created it.".
-nominal instance() :: #inst{}.

%%% ------------------------------------------------------------- lifecycle ---

-doc """
Decode, validate and cache a module, returning a handle.

Use this rather than `compile/1`. Compiling is the expensive step, roughly 20 ms
for a 100 KB Rust binary against 15 us to instantiate one, and loading the same
bytes twice hands you the cached artefact instead of repeating the work.
""".
-spec load(binary()) -> {ok, module_()} | {error, term()}.
load(Binary) -> wasm_module_cache:load(Binary).

-spec load(binary(), map()) -> {ok, module_()} | {error, term()}.
load(Binary, Opts) -> wasm_module_cache:load(Binary, Opts).

-doc "Read a `.wasm` file and load it.".
-spec load_file(file:filename_all()) -> {ok, module_()} | {error, term()}.
load_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> load(Binary);
        {error, Reason} ->
            {error, err(link, file_error, ~"cannot read module file",
                        #{path => Path, reason => Reason})}
    end.

-doc """
Drop your claim on a cached module.

The module stays resident until every holder has released it, so you can call
this safely even when another part of the system loaded the same bytes.
""".
-spec unload(module_()) -> ok.
unload({wasm_module, _} = Handle) -> wasm_module_cache:unload(Handle);
unload(#module{}) -> ok.       % compiled inline; nothing cached to release

-doc """
Decode and validate a module binary without caching it.

Use it for one-shot work. If you instantiate more than once, use `load/1`.
""".
-spec compile(binary()) -> {ok, module_()} | {error, wasm_error:error()}.
compile(Bin) -> compile(Bin, #{}).

-doc """
As `compile/1`, with an `identity` for the module.

Pass one when you already know what names these bytes -- `wasm_module_cache`
passes the content hash it has just computed -- so that anything caching work
derived from the module shares it between two loads of the same bytes. Without
one the module gets a fresh reference, which is correct and simply does not
share. Nothing hashes on this path: five milliseconds on the 1.8 MB QuickJS
module is not worth paying to buy sharing the inline API does not promise.
""".
-spec compile(binary(), map()) -> {ok, module_()} | {error, wasm_error:error()}.
compile(Bin, Opts) ->
    Identity = maps:get(identity, Opts, undefined),
    with_room(byte_size(Bin), fun() ->
        case wasm_decode:module(Bin) of
            {error, _} = E -> E;
            {ok, M} -> wasm_validate:module(M#module{identity = Identity})
        end
    end).

%% Size the heap for the module before building it.
%%
%% A validated module is a large, long-lived structure grown incrementally, and
%% the collector copies the live part of it again at every collection along the
%% way. On the 1.8 MB QuickJS fixture that was 244 ms of which about 190 was
%% collection. Two words per byte of input, with a collection to make the new
%% size take effect immediately, brings the same work to 55 ms.
%%
%% The flag is restored afterwards; the enlarged heap goes back on its own at
%% the next collection, which is ordinary behaviour. Below 16 KB the whole
%% question is worth microseconds and is not asked.
with_room(Bytes, F) when Bytes < 16384 -> F();
with_room(Bytes, F) ->
    Old = erlang:process_flag(min_heap_size, Bytes * 2),
    %% `min_heap_size' takes effect at the next collection, and by then the
    %% thrashing has already happened: setting it without this recovered a
    %% third of the time rather than three quarters.
    erlang:garbage_collect(),
    try F()
    after erlang:process_flag(min_heap_size, Old)
    end.

-doc """
Decode without validating. Use it to inspect a module that fails validation;
do not instantiate what it gives you.
""".
-spec validate(module_()) -> {ok, module_()} | {error, wasm_error:error()}.
validate(M) -> wasm_validate:module(M).

-spec instantiate(module_(), map()) -> {ok, instance()} | {error, wasm_error:error()}.
instantiate(M, Imports) -> instantiate(M, Imports, #{}).

-doc """
Instantiate, resolving imports and running the start function.

`Opts` takes `fuel` and `max_depth`. Both default to permissive values, so a
trusted embedder does not have to opt out of limits. Set them yourself when the
module is untrusted.

**To link modules that exchange garbage-collected references**, name the
instance to share an object store with:

```
{ok, A} = wasm:instantiate(ModA, #{}),
{ok, T} = wasm:extern(A, ~"table"),
{ok, B} = wasm:instantiate(ModB, #{{~"env", ~"t"} => T}, #{link => A}).
```

A reference is an id into a store, so an id from another store means nothing
here and reading one traps with `foreign_reference`. Link this way whenever two
modules pass structs or arrays between them, through a shared table, a shared
global or each other's exports. You do not need it for modules that exchange
only numbers, memories and functions.

You say it explicitly rather than having it inferred from `Imports`, because an
import is a bare handle that does not say which instance produced it: `extern/2`
hands out a table, a memory or a cell, none of which names its origin. Inferring
it would work for some import kinds and not others, which is worse than one rule
that always holds.

**The instance you get back is scoped to your process.** Its mutable state lives
in an ETS table this process owns, so the handle stops working when this process
exits, like a port or an ETS table would. Passing the handle to another process
works while the creator is alive. To give an instance a lifetime of its own, put
a process in charge of it; see `docs/worker.md`.
""".
-spec instantiate(module_(), map(), map()) ->
          {ok, instance()} | {error, wasm_error:error()}.
instantiate({wasm_module, _} = Handle, Imports, Opts) ->
    case wasm_module_cache:get(Handle) of
        {ok, M} -> instantiate(M, Imports, Opts);
        {error, not_loaded} ->
            {error, err(link, module_not_loaded, ~"module is not loaded",
                        #{handle => Handle})}
    end;
instantiate(#module{} = M, Imports, Opts0) ->
    case profile(Opts0) of
        {error, _} = E ->
            E;
        {ok, Opts} ->
            case wasm_instance:new(M, Imports, Opts) of
                {error, _} = E -> E;
                {ok, Inst} -> run_start(M, Inst, Opts)
            end
    end.

%% `profile` names a workload; everything it sets is an option you could have
%% set yourself, and any you did set wins.
%%
%% It exists because the right answers genuinely differ and every one of them is
%% measured. See `docs/compiled-tier.md` and `test/audit/PERF.md`.
profile(#{profile := P} = Opts) ->
    case defaults(P) of
        undefined ->
            {error, err(link, unknown_profile,
                        ~"profile must be plugin or script", #{profile => P})};
        D ->
            {ok, maps:merge(D, Opts)}
    end;
profile(Opts) ->
    {ok, Opts}.

%% A module called many times through a long-lived instance. Run time is what
%% there is to win, and the compile is paid once and amortised over everything
%% after it, so it is worth 2.2x more of it: `full` is 75.0 to 76.8 ms on
%% QuickJS against 86.1 to 87.7 at `baseline`.
defaults(plugin) ->
    #{compile => true, compile_quality => full};
%% A program run end to end, which is usually an interpreter with a script to
%% run. Two things follow. It may be a *single* call, so the default threshold
%% of 32 would never reach it and nothing would ever compile. And the compile
%% is a large share of the whole thing -- 58.1 seconds at `baseline` against
%% 129.3 at `full` for QuickJS's hot set -- so the cheaper one wins unless the
%% same module is run a great many times.
%%
%% Set `code_cache_dir` as well if you run the same module more than once per
%% node: without it that compile is paid at every start. See
%% `wasm_code_cache`.
defaults(script) ->
    #{compile => true, compile_quality => baseline, compile_after => 1};
defaults(_) ->
    undefined.

run_start(#module{start = undefined}, Inst, _Opts) ->
    {ok, Inst};
%% A start function that traps does *not* roll the instance back, and this is
%% not an oversight. The specification says the store keeps what instantiation
%% wrote: `linking.wast' instantiates a module that fills an imported memory,
%% writes a reference to one of its own functions into an imported table and
%% then traps, and requires both the bytes and a call through that reference to
%% work afterwards. Destroying the instance made the second one a
%% `foreign_reference' trap.
%%
%% So the instance stays, reachable through whatever it wrote, and what it
%% holds is released when the process that built it exits.
%%
%% It is *handed over* now, in the error's context under `instance`. It used to
%% be dropped on the floor, and "the builder exits" is not a bound in a process
%% that builds many: every trapping instantiation left its memories, tables and
%% globals held for the life of that process, with no handle anywhere to release
%% them through. A caller that knows nothing escaped can now `destroy/1` it, and
%% one that does not can ignore the field and get exactly the old behaviour.
run_start(#module{start = F}, Inst, Opts) ->
    case invoke(Inst, F, [], Opts) of
        {ok, _} -> {ok, Inst};
        {error, Err} -> {error, abandoned(Err, Inst)}
    end.

%% Only where there is somewhere to put it. An error from a host function is
%% whatever that function returned and is not this module's to reshape.
abandoned(#{ctx := Ctx} = Err, Inst) when is_map(Ctx) ->
    Err#{ctx := Ctx#{instance => Inst}};
abandoned(Err, _Inst) ->
    Err.

%%% ----------------------------------------------------------------- calls ---

-spec call(instance(), binary(), [term()]) ->
          {ok, [term()]} | {error, wasm_error:error()}.
call(Inst, Name, Args) -> call(Inst, Name, Args, #{}).

-spec call(instance(), binary(), [term()], map()) ->
          {ok, [term()]} | {error, wasm_error:error()}.
call(Inst, Name, Args, Opts) ->
    case wasm_instance:export_kind(Inst, Name) of
        {ok, {func, Idx}} -> invoke(Inst, Idx, Args, Opts);
        {ok, Other} ->
            {error, err(link, not_a_function, <<"export is not a function">>,
                        #{name => Name, kind => Other})};
        error ->
            {error, err(link, unknown_export, <<"unknown export">>,
                        #{name => Name})}
    end.

%% As `call/3', but lets a wasm exception escape as a throw instead of turning
%% it into a trap. Used only for wasm-to-wasm links.
call_nested(Inst, Name, Args) ->
    case wasm_instance:export_kind(Inst, Name) of
        {ok, {func, Idx}} -> invoke_nested(Inst, Idx, Args, #{});
        _ -> {error, err(link, unknown_export, <<"unknown export">>,
                         #{name => Name})}
    end.

%% Reads the mutable state once, executes, and writes it back once. Writing
%% back only on success is deliberate: a trap leaves the instance's memory in
%% whatever state the module put it in (the specification says so), but globals
%% and tables mutated on a path that then trapped are not committed, which is
%% the behaviour an embedder can actually reason about.
invoke(Inst, Idx, Args, Opts) ->
    invoke_with(fun wasm_exec:call_toplevel/5, Inst, Idx, Args, Opts).

%% The nested form differs only in which entry point it uses: `call/5' lets an
%% escaping exception through as a throw, `call_toplevel/5' converts it.
invoke_nested(Inst, Idx, Args, Opts) ->
    invoke_with(fun wasm_exec:call/5, Inst, Idx, Args, Opts).

invoke_with(Entry, Inst, Idx, Args, Opts) ->
    %% Depth is counted per process, not per instance. A host import may call
    %% back into the instance that called it, or into another one, and either
    %% way the outer interpreter's locals, operand stack and frames hold
    %% references no root can see. Collecting there would free them.
    invoke_at(Entry, Inst, Idx, Args, Opts, enter()).

invoke_at(Entry, Inst, Idx, Args, Opts, Depth) ->
    Limits = maps:merge(Inst#inst.limits, Opts),
    %% Held for the whole outermost execution, so a collection running in
    %% another process cannot free what this one is holding in an operand stack
    %% or a local, where no root can see it. Nested calls are already inside
    %% this process's lease.
    Heap = Inst#inst.heap,
    Leased = Depth =:= 0 andalso wasm_heap:lease(Heap),
    %% The outermost invocation opens the budget every nested and re-entrant
    %% call then shares. Nested ones inherit it, which is the whole point.
    Budget = case Depth of
                 0 -> wasm_exec:open_budget(Limits);
                 _ -> keep
             end,
    Mut = wasm_instance:mut(Inst),
    %% Compiled code is entered *here*, at the outermost invocation, and nowhere
    %% else. The interpreter's dispatch path is not touched at all: three
    %% separate changes to `run/3', `branch/3' or what they call have cost about
    %% 70% on QuickJS while the synthetic loop measured nothing, and a "is this
    %% callee compiled?" test inside `do_call/4' is exactly that kind of change.
    %% See `test/audit/PERF.md'.
    Entry1 = case Depth of 0 -> wasm_jit:entry(Inst, Limits, Entry); _ -> Entry end,
    try
        settle(Inst, wasm_error:capture(
          fun() ->
              {ok, Results, Mut0} = Entry1(Inst, Mut, Idx, Args, Limits),
              %% At depth zero the call has returned and the operand stack is
              %% empty, so the roots are exactly the globals, the tables, the
              %% passive element segments, the results about to be handed back,
              %% and whatever the embedder is still holding. That is the whole
              %% reason collection can happen here and precisely nowhere else.
              Mut1 = maybe_collect(Inst, Results, Mut0, Depth),
              %% Skip the write-back when nothing was mutated. A function that
              %% only reads (which is most compute) threads the same term
              %% straight through, so `=:=' is a pointer comparison and the
              %% write vanishes. Measured, that write was 177 ns of a 386 ns
              %% call: nearly half the cost of a short invocation was
              %% persisting state that had not changed.
              case Mut1 =:= Mut of
                  true -> ok;
                  false -> ok = wasm_instance:set_mut(Inst, Mut1)
              end,
              {ok, Results}
          end,
          #{func => Idx}))
    catch
        %% A wasm exception on its way to an enclosing `try_table' escapes
        %% rather than returning, and leaves the store just as a trap does.
        Class:Reason:Stack ->
            _ = settle(Inst, {error, escaped}),
            erlang:raise(Class, Reason, Stack)
    after
        %% After the invocation, not before it: what the tier compiles is chosen
        %% from what this process has actually run, and at the start of a call
        %% that record is empty. See `wasm_jit:after_call/2`.
        Depth =:= 0 andalso wasm_jit:after_call(Inst, Limits),
        Budget =:= keep orelse wasm_exec:close_budget(Budget),
        leave(Depth),
        %% The last reader out performs a collection somebody else asked for
        %% and could not do. Safe here even on the way out of a trap: the
        %% interpreter has fully unwound, so nothing in this process holds a
        %% reference that is not a root.
        case wasm_heap:unlease(Heap, Leased) of
            ok -> ok;
            collect_now -> collect_committed(Heap)
        end
    end.

%% Collecting with the store to ourselves, from committed state. Every
%% instance's `#mut{}` has been written back by now, so there is nothing in
%% hand to prefer over what the registry says.
collect_committed(Heap) ->
    try
        Roots = wasm_heap:pins(Heap) ++
                    lists:append([roots_of(V) || V <- wasm_heap:instances(Heap)]),
        ok = wasm_heap:collect(Heap, Roots)
    after
        ok = wasm_heap:release_exclusive(Heap)
    end.

%% What a trapped computation leaves behind.
%%
%% The store keeps whatever the computation did to it before it trapped, which
%% the specification requires and `linking.wast` asserts. Writes that go
%% straight to a shared structure are there already; the ones threaded through
%% the interpreter's own state are not, and the stack that held them has just
%% unwound. `wasm_exec' records each of those as it happens and this is where
%% one is committed.
%%
%% On success there is nothing to do but forget it: the write-back above has
%% already committed a state at least as new.
settle(#inst{ckpt = Key} = Inst, Result) ->
    case erase(Key) of
        undefined ->
            Result;
        Mut ->
            case Result of
                {error, _} ->
                    %% The instance may itself be gone, which is a value rather
                    %% than a reason to lose the original error.
                    _ = wasm_error:capture(
                          fun() -> {ok, wasm_instance:set_mut(Inst, Mut)} end);
                _ ->
                    ok
            end,
            Result
    end.

%% Nesting depth of `invoke_with/5' in this process. Kept in the process
%% dictionary because it belongs to the call stack, not to any instance: two
%% instances calling each other share one Erlang stack and one answer to
%% "is anything above me still running?".
%%
%% Re-entrancy is legitimate and the specification requires it. Two modules may
%% call each other, and `linking.wast` has one call back into a module that is
%% still running. Refusing it fails three of its assertions.
%%
%% It does cost something, and the price is paid elsewhere: a nested call reads
%% the state as of the last write-back, so it cannot see what the outer call has
%% done, and the outer call's own write-back then discards whatever the inner
%% one did. Measured: a host import calling back into its own instance allocated
%% four objects, and the outer call's return dropped the store from four to one.
%% Fixing that means publishing state across a host call rather than snapshotting
%% it per call, which is affordable only once the object store stops living
%% inside `#mut{}'.
enter() ->
    Depth = case get(wasm_call_depth) of
                undefined -> 0;
                N -> N
            end,
    put(wasm_call_depth, Depth + 1),
    Depth.

leave(0) -> erase(wasm_call_depth), ok;
leave(Depth) -> put(wasm_call_depth, Depth), ok.

%% Collection runs only when enough has been allocated since the last one, so a
%% call that allocates nothing pays a single integer comparison.
%%
%% Any reference among the results is pinned: it is about to leave the runtime's
%% sight, and nothing else would keep it alive.
maybe_collect(#inst{heap = Heap} = Inst, Results, Mut, Depth) ->
    %% A reference among the results is about to leave the runtime's sight and
    %% nothing else would keep it alive, so it is pinned before anything else
    %% happens. The embedder releases it with `release/2'.
    ok = pin_all(Heap, Results),
    case Depth =:= 0 andalso wasm_heap:should_collect(Heap) of
        false ->
            %% Nested, or nothing worth tracing. Something above a nested call
            %% holds live references in interpreter state that no root sees.
            Mut;
        true ->
            %% Nobody else may be executing against this store while it is
            %% traced. An upgrade from the lease already held succeeds only if
            %% that lease is the only one, so there is nobody to wait for and
            %% no way to deadlock.
            case wasm_heap:try_exclusive(Heap) of
                false ->
                    %% Another process is inside the store, holding references
                    %% in interpreter state that no root can see. Ask, and
                    %% return: a request blocks nobody, and whoever is last out
                    %% will do it.
                    ok = wasm_heap:request_collect(Heap),
                    Mut;
                true ->
                    collect_in_hand(Heap, Inst, Mut),
                    Mut
            end
    end.

%% Every instance sharing this store is traced, not just the one being called.
%% Linked instances exchange references, so an object this instance can no
%% longer reach may still be reachable from a global or a table belonging to
%% one of the others. The instance doing the collecting uses the state it has
%% in hand rather than the committed copy, which is not written back yet.
collect_in_hand(Heap, Inst, Mut) ->
    try
        Others = [V || V <- wasm_heap:instances(Heap),
                       element(1, V) =/= Inst#inst.id],
        Roots = wasm_heap:pins(Heap) ++ roots_of(Inst#inst.elems, Mut)
                    ++ lists:append([roots_of(V) || V <- Others]),
        ok = wasm_heap:collect(Heap, Roots)
    after
        ok = wasm_heap:release_exclusive(Heap)
    end.

pin_all(_Heap, []) -> ok;
pin_all(Heap, [V | Rest]) -> ok = wasm_heap:pin(Heap, V), pin_all(Heap, Rest).

roots_of(View) ->
    try roots_of(wasm_instance:elems_of(View), wasm_instance:mut_of(View))
    catch
        %% The instance is gone but its registration outlived it. Nothing it
        %% held can be reachable, so it contributes no roots.
        throw:{wasm_error, _} -> []
    end.

roots_of(Elems, Mut) ->
    global_roots(Mut) ++ table_roots(Mut) ++ elem_roots(Elems, Mut).

%% A mutable global holds its value in a shared cell, so the reference has to be
%% read through it rather than taken from the tuple slot.
global_roots(#mut{globals = Globals}) ->
    [case wasm_global:is_global(G) of
         true -> wasm_global:get(G);
         false -> G
     end || G <- tuple_to_list(Globals)].

table_roots(#mut{tables = Tables}) ->
    lists:append([wasm_table:to_list(T) || T <- tuple_to_list(Tables)]).

%% Passive element segments are roots.
%%
%% A segment's elements come from constant expressions, and `struct.new' is a
%% constant expression, so a segment can be the only thing referring to an
%% object. It lives in the *immutable* half of the instance, which is why it was
%% missed: the collector reads its roots from `#mut{}'. A segment that has been
%% dropped can never be read again, so it is not a root.
elem_roots(Elems, #mut{dropped_elems = Dropped}) ->
    lists:append([element(I + 1, Elems)
                  || I <- lists:seq(0, tuple_size(Elems) - 1), not maps:is_key(I, Dropped)]).

-spec get_global(instance(), binary()) ->
          {ok, [term()]} | {error, wasm_error:error()}.
get_global(Inst, Name) ->
    case wasm_instance:export_kind(Inst, Name) of
        {ok, {global, Idx}} ->
            #mut{globals = Gs} = wasm_instance:mut(Inst),
            %% A mutable global is held in a shared cell, so this reads through
            %% it. `extern/2' deliberately does not: an importer needs the cell.
            V = case element(Idx + 1, Gs) of
                    Cell when is_tuple(Cell), element(1, Cell) =:= wasm_global ->
                        wasm_global:get(Cell);
                    Value -> Value
                end,
            %% Same rule as a call result: it is leaving, so it is pinned.
            ok = wasm_heap:pin(Inst#inst.heap, V),
            {ok, [V]};
        _ ->
            {error, err(link, unknown_export, <<"unknown global export">>,
                        #{name => Name})}
    end.

-spec exports(instance()) -> #{binary() => term()}.
exports(Inst) -> wasm_instance:exports(Inst).

-doc """
Keep a garbage-collected reference alive until you release it.

References that leave the runtime are pinned for you: call results,
`get_global/2` results, and the values carried by an uncaught exception. The
runtime cannot see what you are holding, so without a pin the next collection
frees it.

Pin by hand in one case: **your host function keeps a reference it was passed**.
Its arguments are safe for the duration of the call, because collection does not
run below a live frame, and not afterwards.

```erlang
Fun = fun(_Ctx, [Ref]) ->
          ok = wasm:pin(Inst, Ref),          % keeping it past this call
          ets:insert(mine, {last, Ref}),
          {ok, []}
      end.
```

Reference counted, so a reference pinned twice needs releasing twice.
""".
-spec pin(instance(), term()) -> ok.
pin(Inst, Ref) -> wasm_heap:pin(Inst#inst.heap, Ref).

-doc """
Release a reference, letting it be collected once nothing else holds it.

Releasing something that was never pinned is not an error, so you can release
everything you have seen without tracking which ones counted.
""".
-spec release(instance(), term()) -> ok.
release(Inst, Ref) -> wasm_heap:unpin(Inst#inst.heap, Ref).

-doc """
Release every pinned reference.

Use this when you scope references to a request: run the request, take what you
need out of the results, then drop the lot. Without it, pins accumulate for the
life of the instance.
""".
-spec release_all(instance()) -> ok.
release_all(Inst) -> wasm_heap:unpin_all(Inst#inst.heap).

-doc """
Release an instance's memory pages and state.

Idempotent, and optional: pages are released anyway when the owning process
exits. Calling it returns them sooner, which matters when one process creates
and discards many instances.
""".
-spec destroy(instance()) -> ok.
destroy(Inst) ->
    %% Anything the guest opened and did not close goes first, while the
    %% instance is still readable.
    _ = wasm_error:capture(fun() -> wasm_instance:run_cleanups(Inst) end),
    %% This instance's *claim* on each memory, not the memory itself. An
    %% imported one belongs to whoever else still holds it and is very likely
    %% still in use; freeing it outright released pages twice and took the node
    %% counter below zero, where it wrapped to 2^64-1 and refused every
    %% allocation on the node afterwards.
    _ = wasm_error:capture(
          fun() ->
              #mut{mems = Mems, tables = Tables, globals = Globals} =
                  wasm_instance:mut(Inst),
              Token = {instance, Inst#inst.id},
              _ = [wasm_memory:release(Mem, Token)
                   || Mem <- tuple_to_list(Mems)],
              _ = [wasm_table:release(T, Token) || T <- tuple_to_list(Tables)],
              %% Only the mutable ones are cells. An immutable global is a
              %% value in the tuple, with no lifetime to release.
              _ = [wasm_global:release(G, Token) || G <- tuple_to_list(Globals),
                                                    wasm_global:is_global(G)],
              ok
          end),
    %% The compiled code this instance may have claimed. Same argument as the
    %% memories above: the lease names the instance, so it goes when the
    %% instance does, and until this line it went only when the owning process
    %% died. A process serving many distinct modules pinned the sixteen slots
    %% one at a time and then interpreted for ever.
    _ = wasm_error:capture(fun() -> wasm_jit:release(Inst) end),
    %% The object store goes when the last instance sharing it goes, not with
    %% the first: linked instances hold references into one store.
    ok = wasm_heap:delete(Inst#inst.heap, Inst#inst.id),
    %% Releasing the state table last makes this idempotent: a second call finds
    %% it gone, `mut/1' reports a dead instance, and `capture/1' turns that into
    %% a value rather than releasing the same pages twice.
    ok = wasm_instance:release(Inst),
    ok.

-doc """
Take an instance's export in the form another module can import it.

Functions come back as host functions, so wasm-to-wasm linking reuses the same
import mechanism as Erlang-implemented imports rather than needing a second path
through the interpreter.
""".
-spec extern(instance(), binary()) -> {ok, term()} | {error, wasm_error:error()}.
extern(Inst, Name) ->
    case wasm_instance:export_kind(Inst, Name) of
        {ok, {func, _}} ->
            %% A host function must answer `{ok, Results}' or `{trap, Reason}'.
            %% `call/3' answers `{ok, _}' or `{error, _}', so handing it over
            %% directly meant a trap in an imported function arrived as a shape
            %% the interpreter could not match, and surfaced as an internal
            %% `try_clause' error instead of the trap it actually was.
            %%
            %% Re-throwing preserves the callee's class, kind and context, so a
            %% trap crossing a module boundary reads the same as one that did
            %% not cross it.
            %% Tagged with its type, so an importer declaring a different
            %% signature is a link error. An embedder's own function stays a
            %% bare fun and is taken on trust, since it has no type to carry.
            %% Calls through `call_nested/3', not `call/3': an exception must
            %% keep unwinding into the *caller's* instance, where a `try_table'
            %% may catch it. Converting it to an error here would lose it.
            Fun = fun(_Ctx, Args) ->
                      case call_nested(Inst, Name, Args) of
                          {ok, Results} -> {ok, Results};
                          {error, Err} -> erlang:throw({wasm_error, Err})
                      end
                  end,
            {ok, {wasm_func, Fun, wasm_instance:func_type(Inst, Name)}};
        {ok, {global, Idx}} ->
            #mut{globals = Gs} = wasm_instance:mut(Inst),
            %% Tagged with its declared type, for the same reason a function
            %% export is: a bare value cannot say whether it is `funcref',
            %% `(ref func)' or `(ref $t)', and the importer has to check that.
            %% A mutable global hands over its cell so the importer shares it;
            %% an immutable one hands over the value.
            #globaltype{mut = Mut} = GT = wasm_instance:global_type(Inst, Idx),
            case Mut of
                var -> {ok, {wasm_global, element(Idx + 1, Gs), GT}};
                const -> {ok, {wasm_global_const, element(Idx + 1, Gs), GT}}
            end;
        {ok, {tag, Idx}} ->
            %% A tag is an identity: the importer must receive the very same
            %% one, so that a `throw' here is caught by a `catch' there.
            {ok, wasm_instance:tag(Inst, Idx)};
        {ok, {mem, Idx}} ->
            #mut{mems = Ms} = wasm_instance:mut(Inst),
            {ok, element(Idx + 1, Ms)};
        {ok, {table, Idx}} ->
            #mut{tables = Ts} = wasm_instance:mut(Inst),
            %% A table handle is a reference, so the importer shares the table
            %% rather than receiving a snapshot of it.
            {ok, element(Idx + 1, Ts)};
        error ->
            {error, err(link, unknown_export, <<"unknown export">>,
                        #{name => Name})}
    end.

%%% ---------------------------------------------------------- host helpers ---

-doc """
Read a byte range from a host function's instance.

Accepts either an instance or the context map a host function receives, so
imports can be written without unpacking anything.
""".
-spec read_memory(instance() | map(), non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | {error, wasm_error:error()}.
read_memory(Ctx, Addr, Len) ->
    with_memory(Ctx, fun(Mem) -> {ok, wasm_memory:load_bytes(Mem, Addr, Len)} end).

-spec write_memory(instance() | map(), non_neg_integer(), binary()) ->
          ok | {error, wasm_error:error()}.
write_memory(Ctx, Addr, Bin) ->
    with_memory(Ctx, fun(Mem) -> wasm_memory:store_bytes(Mem, Addr, Bin) end).

-spec memory_size(instance() | map()) -> {ok, non_neg_integer()} | {error, term()}.
memory_size(Ctx) ->
    with_memory(Ctx, fun(Mem) -> {ok, wasm_memory:size_pages(Mem)} end).

with_memory(Ctx, Fun) ->
    wasm_error:capture(
      fun() ->
          Mut = case Ctx of
                    #{mut := M} -> M;
                    #inst{} -> wasm_instance:mut(Ctx)
                end,
          case Mut#mut.mems of
              {} -> wasm_error:link_error(no_memory, <<"instance has no memory">>, #{});
              Mems -> Fun(element(1, Mems))
          end
      end).

%%% --------------------------------------------------------------- errors ---

-spec format_error(wasm_error:error()) -> iolist().
format_error(E) -> wasm_error:format(E).

err(Class, Kind, Msg, Ctx) ->
    #{class => Class, kind => Kind, msg => Msg, ctx => Ctx}.
