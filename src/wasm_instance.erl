-module(wasm_instance).
-moduledoc """
Instantiation: turning a validated module into something executable.

You get here through `wasm:instantiate/3`. Read this when you want to know what
instantiating costs, or what a large module defers.

It builds the two halves of an instance. The immutable half (`#inst{}`) holds
everything derived from the module and is shared by every call. The mutable half
(`#mut{}`) holds globals, tables, memories and dropped-segment flags.

The mutable half is threaded functionally through execution and written back
once per call, rather than living in a shared table. A tuple update is a few
nanoseconds; an ETS write is around forty, and `global.get` is on the hot
path. When instances become supervised processes this record becomes the
gen_server's state unchanged, which is why it is already separated.

Building the execution IR happens here too. Blocks carry resolved arities
instead of type indices, so the interpreter never consults the type section, and
the AST's nesting is kept rather than flattened; see `wasm_exec` for why
continuation lists beat a program counter on this VM.

Above 256 functions a module is lowered progressively: a body is turned into IR
the first time it is called, and cached per process, so a large module costs you
what you use of it rather than what it contains.
""".

-include("wasm.hrl").
-include("wasm_validate.hrl").
-include("wasm_exec.hrl").

-export([new/2, new/3, exports/1, export_kind/2, func_type/2, global_type/2]).
-export([params_of/2, value_matches/2]).
-export([tag/2, default_value/1]).
-export([mut/1, set_mut/2, memory/2, heap/1]).
-export([root_view/1, mut_of/1, elems_of/1, release/1]).
-export([remember/1, lookup/1, body_of/2]).
-export([identity/1, code_slot/1, set_code_slot/2, compiler_ir/2]).
-export([ask_compile/1, release_ask/1, executed/1]).
-export([publish/2, unpublish/2, published/1]).
-export([get_extra/2, set_extra/3, on_destroy/2, run_cleanups/1]).
-export([note_entry/2]).

-define(DEFAULT_LIMITS, #{fuel => infinity, max_depth => 1024}).

%% How many instances may be noted before the registry is swept for dead ones.
-define(SWEEP_FLOOR, 128).

%% Functions in a module, above which bodies are lowered on first call rather
%% than at instantiation.
-define(LAZY_THRESHOLD, 256).

%%% --------------------------------------------------------- instantiation ---

-spec new(#module{}, map()) -> {ok, #inst{}} | {error, wasm_error:error()}.
new(M, Imports) -> new(M, Imports, #{}).

-spec new(#module{}, map(), map()) -> {ok, #inst{}} | {error, wasm_error:error()}.
new(M, Imports, Opts) ->
    %% The heap is created before anything is evaluated, because a constant
    %% expression may allocate: `struct.new' is admitted in a global's
    %% initialiser. It is created here rather than inside `build/3' so that an
    %% instantiation which fails part way still releases its tables.
    %% Everything the build acquires is held under this token until the build
    %% succeeds. A ledger threaded through `build/5' was lost the moment the
    %% build threw, because the exception carries the error and not the newest
    %% value from the abandoned stack, so a failed instantiation left its
    %% memories charged until the building process itself exited.
    Build = {build, make_ref()},
    %% The ceiling belongs to the holder, and the holder during a build is the
    %% build. It moves to the instance with everything else when the build
    %% succeeds. Registered before anything is acquired, so the very first
    %% memory is already bounded.
    ok = wasm_keeper:set_limit(
           Build, maps:get(max_memory_pages,
                           maps:merge(?DEFAULT_LIMITS, Opts), infinity)),
    %% After the ceiling and under the build token, so the heap is bounded by
    %% the same `max_memory_pages` as everything else this instance reaches and
    %% moves to the instance with the rest on success.
    case heap_for(M, Opts, Build) of
        {error, _} = HeapError ->
            ok = wasm_keeper:discard(Build),
            HeapError;
        {ok, Heap, Owned} ->
            new_1(M, Imports, Opts, Build, Heap, Owned)
    end.

new_1(M, Imports, Opts, Build, Heap, Owned) ->
    case wasm_error:capture(fun() -> {ok, build(M, Imports, Opts, Heap, Build)} end) of
        {ok, Inst} ->
            %% One step, so there is no window in which the resources belong to
            %% neither the build nor the instance.
            ok = wasm_keeper:transfer(Build, {instance, Inst#inst.id}, self()),
            %% Registered only once the instance exists, because collection
            %% traces every registered instance's roots and a half-built one
            %% has none worth reading.
            ok = wasm_heap:register(Heap, Inst#inst.id, root_view(Inst)),
            %% So a `funcref' naming this instance can be resolved back to it
            %% in this process without the reference having to carry it.
            ok = remember(Inst),
            {ok, Inst};
        {error, _} = Error ->
            ok = wasm_keeper:discard(Build),
            %% Release only a heap this instantiation made. One adopted from a
            %% linked instance belongs to that instance and is still in use.
            %% Nothing was registered, so any key drops the last reference.
            Owned andalso wasm_heap:delete(Heap, undefined),
            Error
    end.

%% Which object store this instance uses.
%%
%% `link' names an instance to share a store with. Instances that can exchange
%% references must share one, because a reference is an id into a store and an
%% id from somewhere else means nothing here. The WebAssembly store is one store
%% shared by every instance in an embedding; this runtime gives each instance
%% its own unless told they are linked.
%%
%% It is explicit rather than inferred from the imports, because an import is a
%% bare handle that does not say which instance produced it. `wasm:extern/2'
%% hands out a table, a memory or a cell, none of which names its origin.
%% Guessing would work for some import kinds and not others, which is worse
%% than one rule that always holds.
heap_for(M, Opts, Token) ->
    case maps:get(link, Opts, undefined) of
        undefined ->
            {ok, case allocates(M) of
                     false -> undefined;
                     true -> wasm_heap:new(Token, self())
                 end, true};
        #inst{heap = Shared} ->
            %% A holder, not an owner. The heap belongs to whoever made it and
            %% goes when the last of them lets go, which is the same rule an
            %% imported memory follows -- including that a ceiling can refuse
            %% it. Linking to a store already larger than this instance is
            %% allowed to reach is a link failure, not a silent admission.
            case wasm_heap:acquire(Shared, Token, self()) of
                ok ->
                    {ok, Shared, false};
                {error, Why} ->
                    %% `link_error/3` throws, which is the idiom everywhere
                    %% else in this module; here the answer has to be a value,
                    %% because this runs before the capture that `build/5` is
                    %% wrapped in.
                    wasm_error:capture(
                      fun() ->
                          wasm_error:link_error(
                            shared_heap_refused,
                            <<"linked object store is past this instance's "
                              "ceiling">>,
                            #{reason => Why})
                      end)
            end
    end.

%% Whether the module can allocate at all. One declaring no struct and no array
%% type never does, so it gets no heap and pays none of its cost: two ETS tables
%% against an instantiation of under three microseconds.
allocates(#module{types = Types}) ->
    lists:any(fun(#subtype{body = #structtype{}}) -> true;
                 (#subtype{body = #arraytype{}}) -> true;
                 (_) -> false
              end, Types).

build(#module{} = M, Imports, Opts, Heap, Build) ->
    %% Fusion can be disabled to compare against the unfused interpreter, which
    %% is how the superinstruction set was measured and how a suspected fusion
    %% bug would be isolated. Bodies lowered later read it from the instance
    %% instead; see `lower/2'.
    case maps:get(fuse, Opts, true) of
        false -> put(wasm_no_fuse, true);
        true -> erase(wasm_no_fuse)
    end,
    %% The context is rebuilt per instance, and canonicalising interns every
    %% recursive group, which is an ETS lookup each. Modules are immutable and
    %% cached, so the result is cached with them rather than recomputed: it cost
    %% a third of instantiation time on a module with thirty type groups.
    Ctx = wasm_validate:cached_context(M),
    Funcs = build_funcs(M, Ctx, Imports),
    %% The store and version are created before anything is evaluated, because
    %% `ref.func' produces a reference that carries its defining instance, and
    %% that reference has to remain usable after it is written into a table
    %% another module imports.
    Inst0 = #inst{
        id = make_ref(),
        ckpt = make_ref(),
        entry_key = make_ref(),
        types = Ctx#ctx.types,
        funcs = Funcs,
        exports = build_exports(M),
        elems = {},
        datas = list_to_tuple([D#data.init || D <- M#module.datas]), globaltypes = Ctx#ctx.globals,
        canon = Ctx#ctx.canon,
        fields = Ctx#ctx.fields,
        kinds = Ctx#ctx.kinds,
        supers = Ctx#ctx.supers,
        tags = build_tags(M, Imports, Ctx),
        heap = Heap,
        limits = maps:merge(?DEFAULT_LIMITS, Opts),
        ctx = Ctx,
        store = holder_new(#mut{globals = {}, tables = {}, mems = {}}),
        identity = M#module.identity,
        version = atomics:new(3, [])
    },
    Shared = Ctx#ctx.shared_globals,
    Holder = {Build, self()},
    Globals = build_globals(M, Imports, Inst0, Shared, Holder),
    %% Constant expressions read globals as values. Dereferencing once here
    %% keeps `eval_const' unaware that a global may be a shared cell.
    GlobalVals = deref(Globals),
    Mems = build_mems(M, Imports, Ctx, Holder),
    Tables = build_tables(M, Imports, GlobalVals, Inst0, Holder),
    ElemVals = [elem_values(E, GlobalVals, Inst0) || E <- M#module.elems],
    Mut0 = #mut{globals = Globals, tables = Tables, mems = Mems},
    Inst = Inst0#inst{elems = list_to_tuple(ElemVals)},
    Mut1 = init_segments(M, Inst, Mut0, ElemVals),
    ok = set_mut(Inst, Mut1),
    Inst.

%%% ----------------------------------------------------------------- funcs ---

%% Imported functions occupy the low indices, matching the validator's context.
build_funcs(#module{imports = Imports, funcs = Funcs} = M, Ctx, Provided) ->
    Host = [resolve_import(I, Ctx, Provided)
            || #import{desc = {func, _}} = I <- Imports],
    list_to_tuple(Host ++ cached_own(M, Ctx, Funcs, length(Host))).

%% The module's own functions, built once per module rather than per instance.
%%
%% `compile_fn/4' reads a `#func{}', the validation context and an index, and
%% all three belong to the module: the index counts *declared* function
%% imports, not the imports an embedder actually supplied. So nothing in the
%% resulting `#fn{}' can differ between two instances of one module, and
%% rebuilding it per instantiation was lowering every body again. For a module
%% below `?LAZY_THRESHOLD' that is the bulk of what instantiation does.
%%
%% One entry, compared with `=:=' against the last module seen, which is the
%% same cache `wasm_validate:cached_context/1' keeps and for the same reason:
%% the common shape is a pool of workers instantiating one module, which hits
%% every time, and hashing a module to key a map costs more than it saves
%% because `phash2' walks all of one.
%%
%% The imported half stays per instance. A `#hostfn{}' closes over the function
%% the embedder provided, and two embedders may provide different ones.
cached_own(M, Ctx, Funcs, NHost) ->
    case get(wasm_funcs_cache) of
        {M, NHost, Own} -> Own;
        _ ->
            Lazy = worth_deferring(Funcs),
            Own = [compile_fn(F, Ctx, Idx, Lazy)
                   || {Idx, F} <- lists:enumerate(NHost, Funcs)],
            put(wasm_funcs_cache, {M, NHost, Own}),
            Own
    end.

%% Deferring costs a dictionary read on every call, and saves lowering code
%% that is never reached. Which way that trades depends entirely on size: a
%% module of a few dozen functions is lowered in microseconds and every one of
%% them is probably called, while a real language runtime has sixteen hundred
%% and a script touches a fraction of them.
%%
%% Measured on a small module, deferring cost a few percent of a call round
%% trip; on a 1.8 MB QuickJS build it cut instantiation from 78 ms to 12 ms and
%% a script from 752 ms to 238 ms. So small modules are lowered up front and
%% large ones are not. The count is the test rather than the total code size,
%% because deciding must not itself walk every body.
worth_deferring(Funcs) -> length(Funcs) > ?LAZY_THRESHOLD.

resolve_import(#import{module = Mod, name = Name, desc = {func, TypeIdx}},
               Ctx, Provided) ->
    #functype{params = P, results = R} = Ft = functype_at(TypeIdx, Ctx),
    FT = {canon_at(TypeIdx, Ctx), canon_supers(TypeIdx, Ctx), Ft},
    case maps:get({Mod, Name}, Provided, undefined) of
        undefined ->
            wasm_error:link_error(unknown_import, <<"unknown import">>,
                                  #{module => Mod, name => Name});
        Fun when is_function(Fun, 2) ->
            %% A bare fun from an embedder carries no type, so it is taken on
            %% trust and adopts the signature the importer declared.
            #hostfn{nparams = length(P), nresults = length(R),
                    fun_ = Fun, name = {Mod, Name}, type = FT};
        {wasm_func, Fun, Actual} when is_function(Fun, 2) ->
            %% An export from another instance does carry its type, so a
            %% mismatched signature is a link error rather than a call that
            %% goes wrong later.
            case same_signature(Actual, FT) of
                true -> ok;
                false ->
                    wasm_error:link_error(incompatible_import_type,
                                          <<"incompatible import type">>,
                                          #{where => {func, Mod, Name},
                                            declared => FT, provided => Actual})
            end,
            #hostfn{nparams = length(P), nresults = length(R),
                    fun_ = Fun, name = {Mod, Name}, type = FT};
        {Module, Function} when is_atom(Module), is_atom(Function) ->
            #hostfn{nparams = length(P), nresults = length(R),
                    fun_ = fun(Ctx1, Args) -> Module:Function(Ctx1, Args) end,
                    name = {Mod, Name}, type = FT};
        Other ->
            wasm_error:link_error(bad_import, <<"import is not callable">>,
                                  #{module => Mod, name => Name, got => Other})
    end.

%% The metadata is cheap and is built now; the body is not, and is left until
%% the function is first called. A real 1.8 MB module has 1666 functions, and
%% lowering all of them cost 21.7 MB per instance for code that is mostly never
%% reached.
compile_fn(#func{type = TypeIdx, locals = Locals, body = Body}, Ctx, Idx, Lazy) ->
    #functype{params = P, results = R} = Ft = functype_at(TypeIdx, Ctx),
    FT = {canon_at(TypeIdx, Ctx), canon_supers(TypeIdx, Ctx), Ft},
    #fn{nparams = length(P),
        nresults = length(R),
        defaults = [default_value(T) || T <- Locals],
        body = case Lazy of true -> {lazy, Body}; false -> ir(Body, Ctx) end,
        raw = Body,
        idx = Idx,
        type = FT,
        frame = {func, length(R)}}.

-doc """
The unfused IR of a function, for the compiler.

Fusion exists to save the interpreter a dispatch and there is no dispatch here
to save, so a superinstruction would only mean a second spelling of a sequence
the generator already handles. This ignores the instance's `fuse` option, which
defaults to on, and reads `#fn.raw` rather than `#fn.body` so that a module
small enough to have been lowered up front still has a source.

Deliberately not cached. It is an intermediate the generator walks once per
function, and caching it would hold a module's worth of IR for nothing.
""".
-spec compiler_ir(#fn{}, #inst{}) -> [term()].
compiler_ir(#fn{raw = Raw}, #inst{ctx = Ctx}) ->
    Prev = get(wasm_no_fuse),
    put(wasm_no_fuse, true),
    try ir(Raw, Ctx)
    after
        case Prev of
            undefined -> erase(wasm_no_fuse);
            _ -> put(wasm_no_fuse, Prev)
        end
    end.

-doc """
Which code slot this instance's compiled module lives in, or `undefined`.

Read on the outermost call, so it is an `atomics:get/2` and not a lookup. Zero
means the module has not been compiled, which is every instance until a hot
call compiles one and every instance of a module the compiler refused.
""".
-spec identity(#inst{}) -> undefined | {sha256, binary()} | reference().
identity(#inst{identity = Id}) -> Id.

-spec code_slot(#inst{}) -> undefined | pos_integer().
code_slot(#inst{version = V}) ->
    case atomics:get(V, ?IX_CODE) of
        0 -> undefined;
        N -> N
    end.

-doc """
Record the slot, once compilation has published into it.

Answers whether this call was the one that set it. Two processes may reach a
hot call at the same moment and both be told the module is resident, and only
one of them should take the instance lease that keeps the slot alive.
""".
-spec set_code_slot(#inst{}, pos_integer()) -> boolean().
set_code_slot(#inst{version = V}, Slot) when Slot > 0 ->
    atomics:compare_exchange(V, ?IX_CODE, 0, Slot) =:= ok.

-doc """
Claim the right to ask for this instance's module to be compiled.

Answers `true` to one caller and then to nobody else for `?ASK_RETRY_SECONDS`.
Compiling a real module takes tens of seconds and happens off the calling
process, so without this every hot call during those seconds would ask again,
and each ask copies the instance to the process that will do the work.

**It records a time rather than setting a flag**, and that is the whole point.
The process doing the work can be killed untrappably, which is what shutdown
does to it, and no `after` covers that. A flag would stay set and this instance
would never be compiled again for the life of the node, with nothing to see. A
time expires, so every way of losing a compiler costs a minute rather than
everything.
""".
-spec ask_compile(#inst{}) -> boolean().
ask_compile(#inst{version = V}) ->
    Now = uptime_seconds(),
    Last = atomics:get(V, ?IX_ASKED),
    case Last =:= 0 orelse Now - Last >= ask_retry_seconds() of
        false -> false;
        true -> atomics:compare_exchange(V, ?IX_ASKED, Last, Now) =:= ok
    end.

%% How long an ask stands. Configurable because it is the only way to observe
%% that it expires at all: a test cannot wait a minute, and an embedder that
%% wants a lost compile retried sooner has no other lever.
ask_retry_seconds() ->
    application:get_env(wasm, compile_retry_seconds, ?ASK_RETRY_SECONDS).

%% Seconds since this node started, always at least one.
%%
%% `erlang:monotonic_time/1` begins at an unspecified point and is routinely
%% negative, so it cannot be compared against a zero meaning "never asked";
%% measuring from `start_time` gives a number that is positive and still
%% immune to the wall clock moving. The `+ 1` keeps zero free for the sentinel.
uptime_seconds() ->
    Elapsed = erlang:monotonic_time() - erlang:system_info(start_time),
    erlang:convert_time_unit(Elapsed, native, second) + 1.

-doc """
Give an ask back, for one that came to nothing.

No slot free, or another process got there first. Those should be retried at
the next hot call rather than after the retry interval, which is the only
reason this exists: the interval alone would already be correct.
""".
-spec release_ask(#inst{}) -> ok.
release_ask(#inst{version = V}) ->
    atomics:put(V, ?IX_ASKED, 0),
    ok.

-doc """
The execution IR of a function, building it the first time it is asked for.

Cached in this process's dictionary, which is where it has to be: a dictionary
read is 9 ns and copies nothing, where reading the IR out of a table would copy
the whole function body on every call.
""".
-spec body_of(#fn{}, #inst{}) -> [term()].
body_of(#fn{body = {lazy, Raw}, idx = Idx}, #inst{id = Id} = Inst) ->
    Key = {wasm_ir, Id, Idx},
    case get(Key) of
        undefined ->
            IR = lower(Raw, Inst),
            put(Key, IR),
            %% Remembering which indices were lowered, so releasing an instance
            %% erases exactly those. Scanning the whole dictionary instead cost
            %% more than instantiation did.
            put({wasm_ir_keys, Id}, [Idx | ir_keys(Id)]),
            %% And noting the instance, so that a process which calls without
            %% instantiating still gets swept. A module's worth of lowered
            %% bodies is megabytes to leak otherwise.
            ok = note(Id, Inst#inst.store),
            IR;
        IR ->
            IR
    end;
body_of(#fn{body = IR}, _Inst) ->
    IR.

%% Lowering reads the fusion decision from the process dictionary, and nested
%% blocks lower recursively, so the flag is set around the whole call rather
%% than threaded through it. It comes off the instance, not from whatever the
%% calling process happens to have set: the decision belongs to the instance
%% that was built with `fuse => false', and deferring the lowering would
%% otherwise hand it to whichever process called first.
lower(Raw, #inst{limits = L, ctx = Ctx}) ->
    Prev = get(wasm_no_fuse),
    case maps:get(fuse, L, true) of
        false -> put(wasm_no_fuse, true);
        true -> erase(wasm_no_fuse)
    end,
    try ir(Raw, Ctx)
    after
        case Prev of
            undefined -> erase(wasm_no_fuse);
            _ -> put(wasm_no_fuse, Prev)
        end
    end.

%% Locals are zero-initialised, and references start null. Doing this once at
%% instantiation means frame setup is a single `list_to_tuple'.
default_value(i32) -> 0;
default_value(i64) -> 0;
default_value(f32) -> 0.0;
default_value(f64) -> 0.0;
default_value(v128) -> wasm_simd:zero();
%% References start null. A non-nullable local has no default at all, but the
%% validator has already proved it is assigned before it is read, so the value
%% put here is a placeholder that is never observable. A non-nullable table or
%% global does not reach this: both must carry an initialiser expression, which
%% `wasm_validate' enforces.
default_value({ref, _, _}) -> null.

%%% -------------------------------------------------------------------- IR ---

%% Resolve block signatures to plain arities. The interpreter then never needs
%% the type section, and `br' can slice the operand stack by counting alone.
%% A peephole pass then fuses the most common adjacent sequences.
ir({validated, Ann}, Ctx) -> ir(Ann, Ctx);
ir(Instrs, Ctx) ->
    Lowered = [ir_instr(unann(I), Ctx) || I <- Instrs],
    case get(wasm_no_fuse) of
        true -> Lowered;      % `fuse => false': benchmarking and bug isolation
        _ -> fuse(Lowered)
    end.

%% The validator's annotation, dropped here. The heights it carries are for a
%% compiler assigning operands to slots; this interpreter reads its operands off
%% `#st.stack` and has no use for them yet.
%%
%% Told apart from an instruction by the integer at the head: an annotated
%% instruction is `{Height, Instr}` or `{Height, Base, Instr}`, and no
%% instruction is a tuple whose first element is a number. So a body that was
%% never validated passes through unchanged rather than being misread, which
%% matters because `wasm_wat` builds modules the validator has not seen.
unann({H, _Base, I}) when is_integer(H) -> I;
unann({H, I}) when is_integer(H) -> I;
unann(I) -> I.

%% Superinstructions.
%%
%% Chosen from measured frequencies over ~25000 instructions of real Rust and
%% clang output, not from guesswork. In that sample `local.get' alone is 28.3%
%% of the stream and `i32.const' another 17.6%, and the pairs and triples below
%% are the most common adjacencies:
%%
%% ```
%%   local.get, i32.const              2069   8.3% of pairs
%%   local.get, local.get              1860   7.4%
%%   local.get, i32.const, i32.add      887   3.6% of triples  (address maths)
%%   local.get, i32.load                768   3.1%
%%   i32.eqz, br_if                     383   1.5%
%% ```
%%
%% Rebuilt over 45,810 instructions of the same kind of output before the
%% longer rules below were chosen, because guessing at them from one benchmark
%% loop produced a different and wrong set. What that showed is that the
%% valuable extensions are not new pairs but the *consumers* of the rules
%% already here, which the greedy left-to-right match leaves stranded:
%%
%% ```
%%   after local.get local.get      i32.store   667   the top successor by far
%%   after local.get i32.load       local.tee   542   the only common one
%%   after local.get i32.const i32.add
%%                                  local.set   304
%%                                  local.tee   253
%% ```
%%
%% A new *pair* would mostly steal instructions the existing rules already
%% fuse, which is why the frequency of a pair on its own says little: what
%% matters is whether the instruction it consumes had anywhere else to go.
%%
%% Only straight-line sequences are fused. A sequence like `br_if, local.get'
%% is a frequent adjacency but must never be merged: the `local.get' runs only
%% when the branch is not taken. Every fusion here has both instructions always
%% executing, in the same order, with the same traps.
%%
%% Longest match first, so triples are not stolen by the pair rules and quads
%% are not stolen by the triples.
fuse([{local_get, I}, {i32_const, C}, i32_add, {local_set, T} | R]) ->
    [{lg_const_add_set, I + 1, C, T + 1} | fuse(R)];
fuse([{local_get, I}, {i32_const, C}, i32_add, {local_tee, T} | R]) ->
    [{lg_const_add_tee, I + 1, C, T + 1} | fuse(R)];
fuse([{local_get, I}, {i32_const, C}, i32_add | R]) ->
    [{lg_const_add, I + 1, C} | fuse(R)];
%% The address is the first local, the value the second: `i32.store' pops the
%% value it was given last.
fuse([{local_get, I}, {local_get, J}, {i32_store, {_, _, _} = MA} | R]) ->
    [{lg_lg_store, I + 1, J + 1, MA} | fuse(R)];
fuse([{local_get, I}, {i32_load, {_, _, _} = MA}, {local_tee, T} | R]) ->
    [{lg_load_tee, I + 1, MA, T + 1} | fuse(R)];
%% Only the 32-bit memarg fuses. A 64-bit memory tags its memarg with a fourth
%% element, and the fused form has no room for the width; leaving those two
%% instructions unfused costs one extra dispatch on a path memory64 modules
%% take anyway.
fuse([{local_get, I}, {i32_load, {_, _, _} = MA} | R]) ->
    [{lg_load, I + 1, MA} | fuse(R)];
fuse([{local_get, I}, {local_get, J} | R]) ->
    [{lg_lg, I + 1, J + 1} | fuse(R)];
fuse([{local_get, I}, {i32_const, C} | R]) ->
    [{lg_const, I + 1, C} | fuse(R)];
fuse([i32_eqz, {br_if, N} | R]) ->
    [{eqz_br_if, N} | fuse(R)];
fuse([I | R]) -> [I | fuse(R)];
fuse([]) -> [].

ir_instr({block, BT, Body}, Ctx) ->
    {NPar, NRes} = arity(BT, Ctx),
    {block, NPar, NRes, ir(Body, Ctx)};
ir_instr({loop, BT, Body}, Ctx) ->
    {NPar, NRes} = arity(BT, Ctx),
    {loop, NPar, NRes, ir(Body, Ctx)};
ir_instr({try_table, BT, Catches, Body}, Ctx) ->
    {NPar, NRes} = arity(BT, Ctx),
    {try_table, NPar, NRes, Catches, ir(Body, Ctx)};
ir_instr({if_, BT, Then, Else}, Ctx) ->
    {NPar, NRes} = arity(BT, Ctx),
    {if_, NPar, NRes, ir(Then, Ctx), ir(Else, Ctx)};
%% Memory instructions carry their memory's address width, resolved here
%% because the interpreter must not pay a lookup per access. `i32' memories
%% keep the three-element memarg they already had, so nothing changes for them.
%%
%% A vector load or store shares this shape but not this handling: its result
%% is a lane pattern rather than a scalar, so it is tagged with the number of
%% bytes it touches and handed to `wasm_simd'.
ir_instr({Op, {Align, Offset, M}}, Ctx) when is_atom(Op) ->
    case wasm_validate_simd:mem_op(Op) of
        {load, Natural} ->
            {simd_load, Op, Offset, M, addr_width(M, Ctx), 1 bsl Natural};
        {store, _} ->
            {simd_store, Offset, M, addr_width(M, Ctx)};
        false ->
            case wasm_validate_atomic:mem_op(Op) of
                %% Tagged with its kind and width so the interpreter never
                %% parses an instruction name, and never has to tell an atomic
                %% memory argument from an ordinary one at run time.
                {Kind, T, Width} ->
                    {atomic, Kind, Width, T, Offset, M, addr_width(M, Ctx)};
                false ->
                    case addr_width(M, Ctx) of
                        32 -> {Op, {Align, Offset, M}};
                        64 -> {Op, {Align, Offset, M, 64}}
                    end
            end
    end;
ir_instr({memory_grow, M} = I, Ctx) -> width_tagged(I, M, Ctx);
ir_instr({memory_fill, M} = I, Ctx) -> width_tagged(I, M, Ctx);
%% `memory.copy' is the one bulk operation that names two memories, and under
%% multiple memories they may have different index types. Both widths are
%% resolved here so the interpreter does not have to look either of them up.
ir_instr({memory_copy, D, S}, Ctx) ->
    case {addr_width(D, Ctx), addr_width(S, Ctx)} of
        {32, 32} -> {memory_copy, D, S};
        {DW, SW} -> {memory_copy, D, S, DW, SW}
    end;
ir_instr({memory_init, _, M} = I, Ctx) -> width_tagged(I, M, Ctx);
%% - vectors ---------------------------------------------------------------
%% Vector instructions are tagged by *shape* here so the interpreter dispatches
%% on the shape rather than testing 240 atoms. The shape comes from the same
%% type table the validator uses, so the two cannot drift apart.
%% A global that another module can observe is a cell; every other global stays
%% an inline value. Deciding it here is what keeps `global.get' a tuple read on
%% the common path, which matters because compiler output reads the shadow stack
%% pointer on nearly every function entry.
ir_instr({global_get, I}, #ctx{shared_globals = Sh}) when is_map_key(I, Sh) ->
    {global_get_ref, I};
ir_instr({global_set, I}, #ctx{shared_globals = Sh}) when is_map_key(I, Sh) ->
    {global_set_ref, I};
%% The label list becomes a tuple. Selecting one was `length/1' and then
%% `lists:nth/2', two walks of the list on every dispatch, where a tuple makes
%% it `tuple_size/1' and `element/2' and neither depends on how many labels
%% there are. A jump table with one entry pays the same as one with a hundred,
%% which is the shape a `switch' compiles to.
ir_instr({br_table, Labels, Default}, _Ctx) ->
    {br_table, list_to_tuple(Labels), Default};
ir_instr({v128_const, _} = I, _Ctx) -> I;
ir_instr({i8x16_shuffle, _} = I, _Ctx) -> I;
ir_instr({Op, {_Align, Offset, M}, Lane}, Ctx) when is_atom(Op) ->
    {Dir, Natural, _} = wasm_validate_simd:lane_mem_op(Op),
    simd_mem(Dir, Op, Offset, M, Natural, Lane, Ctx);
ir_instr({Op, Lane}, Ctx) when is_atom(Op), is_integer(Lane) ->
    case wasm_validate_simd:lane_op(Op) of
        {_, [v128], _} -> {simd_lane, Op, Lane};
        {_, [v128, _], _} -> {simd_replace, Op, Lane};
        false -> ir_default({Op, Lane}, Ctx)
    end;
ir_instr(Op, _Ctx) when is_atom(Op) ->
    case wasm_validate_simd:type_of(Op) of
        {[v128, v128], _} -> {simd_binary, Op};
        {[v128, i32], [v128]} -> {simd_shift, Op};
        {[v128, v128, v128], _} -> {simd_ternary, Op};
        {[v128], _} -> {simd_unary, Op};
        {[_], [v128]} -> {simd_splat, Op};
        false -> Op
    end;
ir_instr(I, Ctx) -> ir_default(I, Ctx).

ir_default(I, _Ctx) -> I.

%% Vector loads and stores read or write exactly `1 bsl Natural' bytes, which
%% is why the natural alignment doubles as the access width: `v128.load32_splat'
%% has natural alignment 2 and reads four bytes.
simd_mem(load, Op, Offset, M, Natural, Lane, Ctx) ->
    {simd_load_lane, Op, Offset, M, addr_width(M, Ctx), 1 bsl Natural, Lane};
simd_mem(store, Op, Offset, M, _Natural, Lane, Ctx) ->
    {simd_store_lane, Op, Offset, M, addr_width(M, Ctx), Lane}.

width_tagged(I, M, Ctx) ->
    case addr_width(M, Ctx) of
        32 -> I;
        64 -> erlang:append_element(I, 64)
    end.

addr_width(M, #ctx{mems = Ms}) when M < tuple_size(Ms) ->
    #memtype{limits = #limits{index_type = T}} = element(M + 1, Ms),
    case T of i32 -> 32; i64 -> 64 end;
addr_width(_, _) -> 32.

arity(empty, _Ctx) -> {0, 0};
arity({valtype, _}, _Ctx) -> {0, 1};
arity({typeidx, I}, #ctx{types = Ts}) ->
    #functype{params = P, results = R} = unwrap_func(element(I + 1, Ts)),
    {length(P), length(R)}.

%%% -------------------------------------------------------------- segments ---

%% A tag is an identity, not a value: two modules that import the same tag must
%% agree that a `throw' from one is caught by a `catch' in the other, and two
%% distinct tags with identical types must stay distinct. A bare reference is
%% all that takes, since a tag has no mutable content.
build_tags(#module{imports = Imports, tags = Tags}, Provided, Ctx) ->
    Imported = [import_tag(I, Provided, Ctx)
                || #import{desc = {tag, _}} = I <- Imports],
    Own = [{wasm_tag, make_ref(), tag_canon(T, Ctx), tag_type(T, Ctx)}
           || T <- Tags],
    list_to_tuple(Imported ++ Own).

tag_type(#tagtype{type = T}, Ctx) -> functype_at(T, Ctx).

%% A tag is identified by the *canonical* identity of its type, not by the
%% type's shape. Two structurally identical types in one recursive group are
%% different types, so a tag declared with one must not link against a tag
%% declared with the other.
tag_canon(#tagtype{type = T}, #ctx{canon = C}) -> element(T + 1, C).

functype_at(Idx, #ctx{types = Ts}) -> unwrap_func(element(Idx + 1, Ts)).

canon_at(Idx, #ctx{canon = C}) -> element(Idx + 1, C).

%% Every type this one is a subtype of, canonically.
%%
%% Carried with the function because `call_indirect' requires the callee's type
%% to be a *subtype* of the declared one, and the callee may live in another
%% module whose supertype indices mean nothing here.
canon_supers(Idx, #ctx{types = Ts, canon = C}) ->
    wasm_types:canon_supers(Idx, Ts, C).

%% Compared on canonical identity. A `#functype{}' naming `{type, 3}' means
%% whatever type index 3 is *in its own module*, so comparing the records
%% directly makes two modules disagree about types they both got from a third.
same_signature(undefined, _Want) -> true;
same_signature({_, Supers, _}, {Want, _, _}) -> lists:member(Want, Supers);
same_signature(_, _) -> false.

unwrap_func(#subtype{body = #functype{} = F}) -> F.

import_tag(#import{module = Mod, name = Name, desc = {tag, TT}}, Provided, Ctx) ->
    Want = tag_canon(TT, Ctx),
    case maps:get({Mod, Name}, Provided, undefined) of
        undefined -> link_missing(Mod, Name);
        {wasm_tag, _Id, Want, _FT} = Tag -> Tag;
        Other ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"incompatible import type">>,
                                  #{where => {tag, Mod, Name},
                                    declared => Want, provided => Other})
    end.

build_globals(#module{imports = Imports, globals = Globals}, Provided, Inst,
              Shared, Holder) ->
    Imported = [hold_global(import_global(I, Provided), Holder)
                || #import{desc = {global, _}} = I <- Imports],
    NImported = length(Imported),
    %% Each initialiser sees the globals evaluated before it, which is exactly
    %% the scope the validator enforced. An initialiser reading an imported
    %% global reads through its cell, so `eval_const' is given values.
    lists:foldl(
      fun({Offset, #global{init = Init}}, Acc) ->
          V = eval_const(Init, deref(Acc), Inst),
          Idx = NImported + Offset,
          %% A global this module exports has to be a cell from the start:
          %% `wasm:extern/2' cannot hand out a reference to a tuple slot.
          case maps:is_key(Idx, Shared) of
              true -> erlang:append_element(Acc,
                                           wasm_global:new(V, #{holder => Holder}));
              false -> erlang:append_element(Acc, V)
          end
      end, list_to_tuple(Imported), lists:enumerate(0, Globals)).

%% Only a mutable global crosses the boundary as a cell; an immutable one is a
%% value with no lifetime of its own to hold.
hold_global(G, {Token, Owner}) ->
    case wasm_global:is_global(G) of
        false -> G;
        true ->
            case wasm_global:acquire(G, Token, Owner) of
                ok -> G;
                {error, _} ->
                    wasm_error:link_error(incompatible_import_type,
                                          <<"global has been released">>,
                                          #{where => global})
            end
    end.

%% Globals as plain values, for the constant-expression evaluator.
deref(Globals) ->
    list_to_tuple([case wasm_global:is_global(G) of
                       true -> wasm_global:get(G);
                       false -> G
                   end || G <- tuple_to_list(Globals)]).

%% An imported global must match in both value type and mutability. Mutability
%% matters in both directions: importing a mutable global as immutable would
%% let the module observe changes it believes cannot happen, and the reverse
%% would let it write where the provider expects a constant.
%% An import may arrive in one of three shapes, and the shape is part of the
%% check.
%%
%% `wasm:extern/2' tags a global with its declared type, because a bare value
%% cannot say whether it is `funcref', `(ref func)' or `(ref $t)'. A mutable
%% global additionally hands over its cell rather than a snapshot. An embedder
%% passing a bare term gets the older, weaker check: the value's shape, and
%% immutable by construction, since there was never a way to write to it.
import_global(#import{module = Mod, name = Name,
                      desc = {global, #globaltype{valtype = VT, mut = Mut}}},
              Provided) ->
    case maps:get({Mod, Name}, Provided, undefined) of
        undefined -> link_missing(Mod, Name);
        {wasm_global, Cell, #globaltype{valtype = Actual, mut = var}} ->
            check_mutability(Mut, var, Mod, Name),
            %% A mutable global is invariant: the importer may write to it, so
            %% a subtype would let it store a value the exporter's type forbids.
            check_global_type(Actual =:= VT, Mod, Name, Actual, VT),
            Cell;
        {wasm_global_const, Value, #globaltype{valtype = Actual, mut = const}} ->
            check_mutability(Mut, const, Mod, Name),
            check_global_type(subtype(Actual, VT), Mod, Name, Actual, VT),
            Value;
        V ->
            check_mutability(Mut, const, Mod, Name),
            check_global_type(value_matches(VT, V), Mod, Name, unknown, VT),
            V
    end.

check_mutability(var, var, _Mod, _Name) -> ok;
check_mutability(const, const, _Mod, _Name) -> ok;
check_mutability(Declared, _Got, Mod, Name) ->
    wasm_error:link_error(incompatible_import_type,
                          <<"incompatible import type">>,
                          #{where => {global, Mod, Name},
                            reason => mutability_mismatch, declared => Declared}).

check_global_type(true, _Mod, _Name, _Actual, _Declared) -> ok;
check_global_type(false, Mod, Name, Actual, Declared) ->
    wasm_error:link_error(incompatible_import_type,
                          <<"incompatible import type">>,
                          #{where => {global, Mod, Name},
                            declared => Declared, provided => Actual}).

%% Subtyping outside the validator's operand stack. Reference types are the
%% only ones with a non-trivial relation, so everything else is equality.
subtype(T, T) -> true;
subtype({ref, N1, H1}, {ref, N2, H2}) ->
    (N1 =:= N2 orelse N2 =:= null) andalso heap_subtype(H1, H2);
subtype(_, _) -> false.

heap_subtype(H, H) -> true;
heap_subtype(nofunc, H) -> is_func_heap(H);
heap_subtype(noextern, extern) -> true;
heap_subtype({type, _}, func) -> true;
heap_subtype(_, _) -> false.


-doc """
Does this Erlang term satisfy that WebAssembly value type?

The embedder hands over a bare term, for an imported global or for a call
argument, so the check is on the value's shape rather than on a declared type it
does not carry.
""".
-spec value_matches(term(), term()) -> boolean().
value_matches(i32, V) -> is_integer(V);
value_matches(i64, V) -> is_integer(V);
value_matches(f32, V) -> is_float(V) orelse is_float_special(V);
value_matches(f64, V) -> is_float(V) orelse is_float_special(V);
value_matches(v128, V) -> wasm_simd:is_v128(V);
%% Only a nullable reference may be satisfied by null.
value_matches({ref, null, _}, null) -> true;
value_matches({ref, _, H}, {funcref, _}) -> is_func_heap(H);
%% A `funcref' carries its defining instance since 0.2.0. Matching only the
%% bare two-element form rejected every reference an instance actually produces.
value_matches({ref, _, H}, {funcref, _, _}) -> is_func_heap(H);
value_matches({ref, _, extern}, _) -> true;
value_matches(_, _) -> false.

is_func_heap(func) -> true;
is_func_heap({type, _}) -> true;
is_func_heap(nofunc) -> true;
is_func_heap(_) -> false.

is_float_special(infinity) -> true;
is_float_special(neg_infinity) -> true;
is_float_special({nan, _, _}) -> true;
is_float_special(_) -> false.

%% Every memory this instance can reach gets a holder token in its name,
%% whether the instance made it or imported it. During the build that token is
%% the build's; it becomes the instance's when the build succeeds. That is what makes destroying
%% one importer harmless to the others: the token goes, the memory stays as
%% long as anybody else holds it, and destroying the same instance twice
%% removes a token that is already absent.
%%
%% Importing the same memory through two slots takes one token, not two,
%% because the token is the same value both times.
build_mems(#module{imports = Imports, mems = Mems}, Provided,
           #ctx{shared_mems = Shared}, Holder) ->
    Imported = [hold(import_memory(I, Provided), Holder)
                || #import{desc = {mem, _}} = I <- Imports],
    N = length(Imported),
    Own = [new_memory(MT, maps:is_key(N + I, Shared), Holder)
           || {I, MT} <- lists:enumerate(0, Mems)],
    list_to_tuple(Imported ++ Own).

%% A memory whose last holder released it between the embedder reading it out
%% and this instance importing it is not a memory to link against.
hold(Mem, {Token, Owner}) ->
    case wasm_memory:acquire(Mem, Token, Owner) of
        ok ->
            Mem;
        {error, instance_limit} ->
            %% An imported memory never passes through `new_memory/2', so this
            %% is the only place a limit can see it. It is exhaustion, not a
            %% link error: the module and the import match, there is just not
            %% enough allowance to hold it.
            wasm_error:exhaustion(memory_limit,
                                  #{requested => wasm_memory:size_pages(Mem)});
        {error, _} ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"memory has been released">>,
                                  #{where => memory})
    end.

%% An imported memory must satisfy the limits the module declared: at least the
%% minimum it expects, and no larger a maximum than it allows. Skipping this is
%% the classic embedding hole. A module compiled against `(memory 2)' indexes
%% freely below 128 KiB; hand it a one-page memory and every access past the
%% first page traps at best, and at worst the module's own bounds reasoning is
%% simply wrong.
import_memory(#import{module = Mod, name = Name,
                      desc = {mem, #memtype{limits = Want}}}, Provided) ->
    case maps:get({Mod, Name}, Provided, undefined) of
        undefined ->
            link_missing(Mod, Name);
        Mem ->
            check_kind(wasm_memory:is_mem(Mem), memory, Mod, Name, Mem),
            Got = wasm_memory:limits(Mem),
            check_shared_match(Want, Got, {memory, Mod, Name}),
            check_limits_match(Want, Got, {memory, Mod, Name}),
            Mem
    end.

%% Sharing has to match exactly, in both directions. A module that imports a
%% memory as shared will use atomics and `wait' on it, and a module that imports
%% one as unshared may assume nothing else can write it. Neither is safe to
%% satisfy with the other kind, so this is not a "at least as permissive"
%% comparison like the limits below it.
check_shared_match(#limits{shared = Want}, #limits{shared = Want}, _What) -> ok;
check_shared_match(#limits{shared = Want}, _Got, What) ->
    wasm_error:link_error(incompatible_import_type,
                          <<"incompatible import type">>,
                          #{what => What, wanted_shared => Want}).

%% The provided entity must be *at least as permissive* as the import declares:
%% its minimum no smaller, and its maximum no larger (an absent maximum being
%% unbounded, and so acceptable only if the import is unbounded too).
check_limits_match(#limits{min = WantMin, max = WantMax, index_type = WantIdx},
                   #limits{min = GotMin, max = GotMax, index_type = GotIdx},
                   Where) ->
    %% The index type has to be identical, not merely compatible: a 32-bit
    %% memory handed to a module expecting a 64-bit one would silently truncate
    %% every address the module computes.
    case WantIdx =:= GotIdx of
        true -> ok;
        false ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"incompatible import type">>,
                                  #{where => Where, reason => index_type_mismatch,
                                    declared => WantIdx, provided => GotIdx})
    end,
    case GotMin >= WantMin of
        true -> ok;
        false ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"incompatible import type">>,
                                  #{where => Where, reason => minimum_too_small,
                                    declared => WantMin, provided => GotMin})
    end,
    case {WantMax, GotMax} of
        {undefined, _} -> ok;
        {_, undefined} ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"incompatible import type">>,
                                  #{where => Where, reason => unbounded_maximum,
                                    declared => WantMax});
        {W, G} when G =< W -> ok;
        {W, G} ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"incompatible import type">>,
                                  #{where => Where, reason => maximum_too_large,
                                    declared => W, provided => G})
    end.

%% The embedder hands over a bare Erlang term, so an import may be satisfied
%% with something of entirely the wrong kind. That is a link error, not an
%% internal one: nothing the embedder passes may raise out of the runtime.
check_kind(true, _Kind, _Mod, _Name, _V) -> ok;
check_kind(false, Kind, Mod, Name, V) ->
    wasm_error:link_error(incompatible_import_type,
                          <<"incompatible import type">>,
                          #{where => {Kind, Mod, Name}, reason => wrong_kind,
                            provided => V}).

link_missing(Mod, Name) ->
    wasm_error:link_error(unknown_import, <<"unknown import">>,
                          #{module => Mod, name => Name}).

new_memory(#memtype{limits = #limits{min = Min} = Limits}, Observable,
           {Token, Owner}) ->
    case wasm_memory:create(Limits, #{observable => Observable,
                                      holder => {Token, Owner}}) of
        {ok, Mem} -> Mem;
        {error, _Why} ->
            wasm_error:exhaustion(memory_limit, #{requested => Min})
    end.

build_tables(#module{imports = Imports, tables = Tables}, Provided, Globals,
             Inst, Holder) ->
    Imported = [hold_table(import_table(I, Provided), Holder)
                || #import{desc = {table, _}} = I <- Imports],
    Own = [new_table(T, Globals, Inst, Holder) || T <- Tables],
    list_to_tuple(Imported ++ Own).

hold_table(Table, {Token, Owner}) ->
    case wasm_table:acquire(Table, Token, Owner) of
        ok -> Table;
        {error, _} ->
            wasm_error:link_error(incompatible_import_type,
                                  <<"table has been released">>,
                                  #{where => table})
    end.

%% Tables are represented as plain tuples, so only the size is observable from
%% the value itself. The element type is checked against the declaration where
%% the provider is another instance, which is where a mismatch could actually
%% arise; a bare tuple from an embedder is taken on trust and documented as such.
import_table(#import{module = Mod, name = Name,
                     desc = {table, #tabletype{limits = Want,
                                               elemtype = WantET}}}, Provided) ->
    case maps:get({Mod, Name}, Provided, undefined) of
        undefined -> link_missing(Mod, Name);
        Table ->
            check_kind(wasm_table:is_table(Table), table, Mod, Name, Table),
            %% The table carries the limits it was declared with, so the same
            %% check applies as for a memory. Its *current* size is what the
            %% minimum is checked against, since a table that has already grown
            %% past its declared minimum still satisfies an importer asking for
            %% no more than that.
            #limits{max = Max, index_type = IdxType} = wasm_table:limits(Table),
            Got = #limits{min = wasm_table:size(Table), max = Max,
                          index_type = IdxType},
            check_limits_match(Want, Got, {table, Mod, Name}),
            %% A table is read *and* written through, so its element type is
            %% invariant: a subtype would let the importer read out something
            %% the exporter's type forbids, and a supertype would let it write
            %% one in.
            check_global_type(wasm_table:elemtype(Table) =:= WantET, Mod, Name,
                              wasm_table:elemtype(Table), WantET),
            Table
    end.

%% Tables are `array', not a flat tuple.
%%
%% A tuple gives O(1) reads, which looks right because `call_indirect' reads on
%% every dynamic call. But it makes every write copy the whole table: measured
%% on 10000 elements, 1000 scattered `table.set' calls cost 3779 us against 17
%% us for `array', and a bulk fill built from sequential `setelement' is O(n^2).
%% For untrusted code that is a denial-of-service vector, not just a slow path.
%%
%% `array' reads cost 5.3 ns against 1.9 ns for `element/2', but an indirect
%% call also does a type check, a fuel charge and frame setup, so the 3.4 ns
%% difference is a few percent of the operation rather than its cost. Luerl
%% reaches the same conclusion for Lua's integer-keyed table part.
new_table(#tabletype{elemtype = ET, init = Init} = TT, Globals, Inst, Holder) ->
    Fill = case Init of
               undefined -> default_value(ET);
               Expr -> eval_const(Expr, Globals, Inst)
           end,
    %% The declaration goes into the table, so `table.grow' refuses past the
    %% maximum wherever the table ends up being used, including in a module
    %% that imported it and cannot see the declaration.
    %%
    %% A table is a reference, not a value: exporting one and importing it
    %% elsewhere must give both instances the same table, not two copies.
    wasm_table:new(TT, Fill, #{holder => Holder}).

elem_values(#elem{init = Inits}, Globals, Inst) ->
    [eval_const(Expr, Globals, Inst) || Expr <- Inits].

%% Active segments are copied into memory and tables at instantiation. The
%% specification requires bounds to be checked here, so a module whose data
%% segment does not fit fails to instantiate rather than trapping later.
init_segments(#module{elems = Elems, datas = Datas}, _Inst, Mut0, ElemVals) ->
    Mut1 = lists:foldl(
             fun({#elem{mode = {active, TableIdx, Offset}}, Vals}, M) ->
                     Base = eval_const_addr(Offset, deref(M#mut.globals)),
                     init_table(M, TableIdx, Base, Vals);
                ({#elem{}, _}, M) -> M
             end, Mut0, lists:zip(Elems, ElemVals)),
    %% Active element segments are dropped after initialisation, and so are
    %% declarative ones: those exist only to make functions referenceable and
    %% have no contents at run time, so a `table.init' naming one must trap
    %% rather than quietly copying from it.
    Dropped = maps:from_keys(
                [I || {I, #elem{mode = Mode}} <- lists:enumerate(0, Elems), Mode =:= declarative orelse element(1, Mode) =:= active],
                true),
    Mut2 = lists:foldl(
             fun(#data{mode = {active, MemIdx, Offset}, init = Bytes}, M) ->
                     Base = eval_const_addr(Offset, deref(M#mut.globals)),
                     Mem = element(MemIdx + 1, M#mut.mems),
                     wasm_memory:store_bytes(Mem, Base, Bytes),
                     M;
                (#data{}, M) -> M
             end, Mut1#mut{dropped_elems = Dropped}, Datas),
    DroppedD = maps:from_keys(
                 [I || {I, #data{mode = {active, _, _}}}
                           <- lists:enumerate(0, Datas)], true),
    Mut2#mut{dropped_datas = DroppedD}.

init_table(M, TableIdx, Base, Vals) ->
    Table = element(TableIdx + 1, M#mut.tables),
    case Base + length(Vals) =< wasm_table:size(Table) of
        false ->
            %% A trap, not a link error. Linking is name and type resolution
            %% and happens before anything runs; an active segment whose offset
            %% does not fit is discovered while *initialising*, which the
            %% specification classes as a trap during instantiation. The suite
            %% checks this with `assert_uninstantiable', which is why getting
            %% the class wrong here failed a dozen cases that were otherwise
            %% behaving correctly.
            wasm_error:trap(out_of_bounds_table_access,
                            #{offset => Base, count => length(Vals),
                              size => wasm_table:size(Table)});
        true ->
            %% Mutates the shared table in place, so `#mut{}' is unchanged: the
            %% table handle it holds already points at the new contents.
            ok = wasm_table:init(Table, Base, Vals),
            M
    end.

%%% ----------------------------------------------- constant expression eval ---

%% Constant expressions were already type-checked, so evaluation only needs the
%% cases the validator admits.
%% Constant expressions may allocate: `struct.new' and friends are permitted in
%% a global's initialiser, so evaluating one can create objects that the
%% instance's heap must then contain. It allocates straight into the instance's
%% heap, which is why `#inst.heap' is filled in before any of this runs.
%%
%% This used to thread a store through the process dictionary, because the
%% store was a term that every allocation replaced. It is a handle now, so
%% there is nothing to thread and nothing to leave behind on a failure.
eval_const(Expr, Globals, Inst) -> hd(eval_const_stack(Expr, Globals, Inst, [])).

const_heap(#inst{heap = H}) -> H.

%% Segment offsets are addresses, so they are reinterpreted as unsigned. A
%% 64-bit memory's offset is an i64 and must not be truncated to 32 bits.
eval_const_addr(Expr, Globals) ->
    wasm_num:to_u64(eval_const(Expr, Globals, undefined)).

%% A function reference carries the instance that defines it, not just an
%% index. Without that, a reference written into a shared table by one module
%% would be read by another as an index into *its own* function space, and
%% silently call the wrong function.
resolve_funcref(F, undefined) -> {funcref, F};
%% Names the instance rather than carrying it, and notes it here rather than
%% relying on `new/3'.
%%
%% That looks redundant, because `new/3' notes the instance too, and it is not:
%% a reference can escape an instantiation that then *fails*. A module whose
%% element segment writes into an imported table and whose next segment is out
%% of bounds traps, and the specification requires the writes already made to
%% persist. The table then holds a reference to an instance that never finished
%% being built, and `linking.wast' calls through it and expects an answer.
%% Removing this passed every other test and failed exactly those two.
resolve_funcref(F, #inst{id = Id} = Inst) ->
    ok = remember(Inst),
    {funcref, Id, F}.

eval_const_stack([], _G, _I, Stack) -> Stack;
eval_const_stack([Op | Rest], G, I, Stack) ->
    eval_const_stack(Rest, G, I, const_step(Op, G, I, Stack)).

const_step({i32_const, V}, _G, _I, S) -> [V | S];
const_step({i64_const, V}, _G, _I, S) -> [V | S];
const_step({f32_const, V}, _G, _I, S) -> [V | S];
const_step({f64_const, V}, _G, _I, S) -> [V | S];
const_step({v128_const, Bytes}, _G, _I, S) -> [Bytes | S];
const_step({struct_new, T}, _G, I, S) ->
    N = length(struct_fields_of(T, I)),
    {RevFs, Rest} = lists:split(N, S),
    [wasm_heap:new_struct(const_heap(I), T, lists:reverse(RevFs)) | Rest];
const_step({struct_new_default, T}, _G, I, S) ->
    Fs = [const_field_default(F) || F <- struct_fields_of(T, I)],
    [wasm_heap:new_struct(const_heap(I), T, Fs) | S];
const_step({array_new, T}, _G, I, [N, V | S]) ->
    Traced = const_traced(array_field_of(T, I)),
    [wasm_heap:new_array(const_heap(I), T, wasm_num:to_u32(N), V, Traced) | S];
const_step({array_new_default, T}, _G, I, [N | S]) ->
    Field = array_field_of(T, I),
    D = const_field_default(Field),
    [wasm_heap:new_array(const_heap(I), T, wasm_num:to_u32(N), D,
                         const_traced(Field)) | S];
const_step({array_new_fixed, T, N}, _G, I, S) ->
    {RevVs, Rest} = lists:split(N, S),
    H = const_heap(I),
    Ref = wasm_heap:new_array(H, T, N, undefined,
                              const_traced(array_field_of(T, I))),
    lists:foreach(fun({Idx, V}) -> wasm_heap:array_set(H, Ref, Idx, V) end,
                  lists:enumerate(0, lists:reverse(RevVs))),
    [Ref | Rest];
const_step(ref_i31, _G, _I, [V | S]) -> [{i31, V band 16#7FFFFFFF} | S];
const_step(Op, _G, _I, S) when Op =:= any_convert_extern;
                               Op =:= extern_convert_any -> S;
const_step({ref_null, _}, _G, _I, S) -> [null | S];
const_step({ref_func, F}, _G, I, S) -> [resolve_funcref(F, I) | S];
const_step({global_get, Idx}, G, _I, S) -> [element(Idx + 1, G) | S];
const_step(i32_add, _G, _I, [B, A | S]) -> [wasm_num:wrap_s32(A + B) | S];
const_step(i32_sub, _G, _I, [B, A | S]) -> [wasm_num:wrap_s32(A - B) | S];
const_step(i32_mul, _G, _I, [B, A | S]) -> [wasm_num:wrap_s32(A * B) | S];
const_step(i64_add, _G, _I, [B, A | S]) -> [wasm_num:wrap_s64(A + B) | S];
const_step(i64_sub, _G, _I, [B, A | S]) -> [wasm_num:wrap_s64(A - B) | S];
const_step(i64_mul, _G, _I, [B, A | S]) -> [wasm_num:wrap_s64(A * B) | S].

%% Whether an array's elements can hold references. An array of numbers is a
%% leaf and the collector never walks it.
const_traced(#fieldtype{type = {ref, _, _}}) -> true;
const_traced(#fieldtype{}) -> false.

struct_fields_of(T, #inst{types = Ts}) ->
    #structtype{fields = Fs} = (element(T + 1, Ts))#subtype.body,
    Fs;
struct_fields_of(_T, undefined) -> [].

array_field_of(T, #inst{types = Ts}) ->
    #arraytype{field = F} = (element(T + 1, Ts))#subtype.body,
    F.

const_field_default(#fieldtype{type = i8}) -> 0;
const_field_default(#fieldtype{type = i16}) -> 0;
const_field_default(#fieldtype{type = T}) -> default_value(T).

%%% --------------------------------------------------------------- exports ---

build_exports(#module{exports = Exports}) ->
    maps:from_list([{Name, Desc} || #export{name = Name, desc = Desc} <- Exports]).

-spec exports(#inst{}) -> #{binary() => term()}.
exports(#inst{exports = E}) -> E.

-spec export_kind(#inst{}, binary()) -> {ok, term()} | error.
export_kind(#inst{exports = E}, Name) -> maps:find(Name, E).

-doc "A tag's identity, in the form another module can import it.".
-spec tag(#inst{}, non_neg_integer()) -> term().
tag(#inst{tags = Ts}, Idx) -> element(Idx + 1, Ts).

-doc "The declared type of a global by index.".
-spec global_type(#inst{}, non_neg_integer()) -> #globaltype{}.
global_type(#inst{globaltypes = Gs}, Idx) -> element(Idx + 1, Gs).

-doc "The declared type of an exported function.".
-spec func_type(#inst{}, binary()) -> term() | undefined.
func_type(#inst{exports = E, funcs = Fs}, Name) ->
    case maps:find(Name, E) of
        {ok, {func, Idx}} ->
            case element(Idx + 1, Fs) of
                #fn{type = T} -> T;
                #hostfn{type = T} -> T
            end;
        _ -> undefined
    end.

-doc """
The parameter types of an exported function, or `undefined`.

`func_type/2` answers what the function carries, which is a canonical id, its
supertypes and the `#functype{}`. A caller checking arguments wants only the
last part, and unwrapping it at each call site is how the two shapes get
confused.
""".
-spec params_of(#inst{}, binary()) -> [valtype()] | undefined.
params_of(Inst, Name) ->
    case func_type(Inst, Name) of
        {_Canon, _Supers, #functype{params = P}} -> P;
        #functype{params = P} -> P;
        undefined -> undefined
    end.

-spec memory(#inst{}, non_neg_integer()) -> wasm_memory:mem().
memory(Inst, Idx) ->
    #mut{mems = Mems} = mut(Inst),
    element(Idx + 1, Mems).

%%% ------------------------------------------------------ mutable-state holder ---
%%
%% A one-row ETS table standing in for the process that will own this state at
%% milestone M6. It is read once and written once per call, never per
%% instruction, so its cost does not appear on any hot path.

%% The holder is an ETS table owned by whichever process called
%% `wasm:instantiate/2'. That makes a bare instance handle *process-scoped*:
%% it stays valid for as long as its creator lives, exactly like a port or an
%% ETS table, and dies with it.
%%
%% This is a deliberate semantic rather than an oversight. Sharing an instance
%% across processes without a lifetime owner would mean either a global
%% registry that leaks, or reference counting that Erlang does not provide for
%% ETS. Embedders that need a shareable instance own it in a process; see
%% `docs/worker.md', which is exactly this pattern.
holder_new(Mut) ->
    T = ets:new(wasm_instance_store, [set, public, {read_concurrency, true}]),
    ets:insert(T, {state, Mut}),
    T.

-doc """
The instance's current mutable state.

Reading it out of ETS copies the whole `#mut{}` term, which measured 105 ns
against 30 ns for the same lookup returning an atom: the cost is the copy,
not the table. On a short call that was more than half the total.

So each process caches the last state it saw, alongside the version counter
it was current at. A cache hit is an `atomics:get` plus a process dictionary
lookup, neither of which copies anything. The counter is what keeps this
honest across processes: a write by anyone bumps it, and every other
process's cache is invalidated the next time it looks.
""".
-spec mut(#inst{}) -> #mut{}.
mut(#inst{store = T, version = V, id = Id}) ->
    %% A call in flight in this process publishes its state before handing
    %% control to a host function, so a nested call into the same instance sees
    %% what the outer call has done rather than the last committed copy.
    case get({wasm_inflight, Id}) of
        undefined -> mut_at(T, V, Id);
        Mut -> Mut
    end.

mut_at(T, V, Id) ->
    Now = atomics:get(V, ?IX_VERSION),
    case get({wasm_mut_cache, Id}) of
        {Now, Cached} -> Cached;
        _ -> cache_fill(T, Id, Now)
    end.

cache_fill(T, Id, Version) ->
    Mut = load_mut(T),
    put({wasm_mut_cache, Id}, {Version, Mut}),
    %% Noted here, not only at instantiation, because a process that only
    %% *calls* instances created elsewhere fills this cache and used to have
    %% nothing that would ever empty it again. Off the hot path: a cache hit
    %% never reaches here.
    %%
    %% Taking the id and the table rather than the instance is what lets
    %% `mut_of/1' come through here too: a root view carries those two and no
    %% `#inst{}', and requiring one crashed every collection whose cache was
    %% cold.
    ok = note(Id, T),
    Mut.

load_mut(T) ->
    try ets:lookup_element(T, state, 2) of
        Mut -> Mut
    catch
        %% The owning process is gone, taking the table with it. Reporting this
        %% as a structured error beats surfacing a bare `ets:lookup' badarg
        %% from three layers down, which says nothing about the actual mistake.
        error:badarg -> dead_instance()
    end.

dead_instance() ->
    wasm_error:link_error(
      instance_not_owned,
      <<"instance state is gone: its owning process has exited">>,
      #{hint => <<"a bare instance is scoped to the process that created it; "
                  "own it in a process to share it; see docs/worker.md">>}).

-doc "The instance's object store, or `undefined` if it can never allocate.".
-spec heap(#inst{}) -> undefined | wasm_heap:heap().
heap(#inst{heap = H}) -> H.

-doc """
The four fields a garbage collection root scan reads from an instance.

Registered with the heap so that a collection triggered by one instance can
trace every instance sharing the store. Not the whole `#inst{}`: ETS copies on
insert, and an instance carries its type table, its compiled functions and its
exports, which measured 1.9 us of a 5.7 us instantiation.
""".
-spec root_view(#inst{}) -> term().
root_view(#inst{id = Id, store = Store, version = Version, elems = Elems}) ->
    {Id, Store, Version, Elems}.

-doc """
Release an instance's state table and this process's cache of it.

Two things kept a destroyed instance's state alive. The table holding it is
owned by the creating process and was reclaimed only when that process exited,
so a process creating and discarding many instances accumulated one table each.
And `mut/1` caches the whole `#mut{}` in the process dictionary of every process
that has ever called the instance, keyed by instance id, which was never erased.

Only the calling process's cache can be erased from here. Another process that
called this instance keeps its copy until it next looks, which is the same
bounded staleness the version counter already handles.
""".
-spec release(#inst{}) -> ok.
release(#inst{store = T, id = Id, entry_key = EK}) ->
    %% Belt as well as braces: `forget/1' now reaches the entry from the id,
    %% and this line is what makes the destroying process pay nothing to wait
    %% for a sweep.
    _ = EK =:= undefined orelse erase(EK),
    ok = forget(Id),
    try ets:delete(T) catch error:badarg -> true end,
    ok.

%%% ----------------------------------------------------- instance by name ---
%%
%% A `funcref' names its defining instance by id rather than carrying it. It has
%% to: an instance record holds the module's compiled functions, and `ets:insert'
%% copies a term without preserving sharing, so a table of N references to one
%% instance became N copies of it. A real 1.8 MB module with a 1036-entry table
%% turned into a 19.8 GB write and aborted the emulator.
%%
%% Names are resolved through this process's own dictionary. An instance record
%% is immutable, so a cached one can never be stale and there is no version to
%% check. Remembering costs a pointer, not a copy.

-doc """
Note this instance, so a `funcref` naming it can be resolved here later.

Idempotent and cheap. Called wherever an instance record is in hand and a
reference to it might escape.
""".
-spec remember(#inst{}) -> ok.
remember(#inst{id = Id} = Inst) ->
    case get({wasm_inst, Id}) of
        undefined ->
            ok = note(Id, Inst#inst.store),
            put({wasm_inst, Id}, Inst),
            ok;
        _Already ->
            ok
    end.

-doc """
Note the compiled entry this process has cached for an instance.

`wasm_jit` keys it by a bare `reference()` the instance record carries, which
is what makes a hit one dictionary read with no tuple to build, and also what
stops anything else recognising the entry as belonging to an instance. So
the sweep could not reach it and `release/1` only ever ran in the process that
destroyed the instance: a worker calling instances somebody else destroys kept
one closure for each of them, for as long as it lived.

Recorded against the id, where the sweep already looks.
""".
-spec note_entry(term(), reference()) -> ok.
note_entry(Id, Key) ->
    put({wasm_entry, Id}, Key),
    ok.

-doc """
Note that this process has cached something belonging to this instance.

Enough for the sweep to find it later and no more: the state table, which is
gone when the instance is, against its id. The caches are filled by any process
that *calls* an instance, not only by the one that created it, and a process
that never instantiates anything has no `remember/1` to trigger the sweep and
nothing to test liveness against. Keeping the whole record here instead would
mean retaining a module's worth of compiled functions per instance until the
next sweep.
""".
-spec note(term(), ets:table()) -> ok.
note(Id, T) ->
    case get({wasm_live, Id}) of
        undefined ->
            ok = maybe_sweep(),
            put({wasm_live, Id}, T),
            ok;
        _Already ->
            ok
    end.

%% Without this the dictionary would keep every instance this process ever
%% created, which is a leak the benchmark makes visible immediately: twenty
%% thousand instantiations left fifty thousand entries behind.
%%
%% An entry is dead once its state table is gone, which is exactly what
%% `destroy/1' does, so a sweep drops the instances nobody can use again and
%% keeps the rest. The budget until the next sweep is the number that survived
%% it, never below a floor, so the total cost stays proportional to the
%% instances created rather than quadratic in the ones still alive.
maybe_sweep() ->
    case get(wasm_inst_budget) of
        undefined -> put(wasm_inst_budget, ?SWEEP_FLOOR), ok;
        B when B > 0 -> put(wasm_inst_budget, B - 1), ok;
        _Spent -> put(wasm_inst_budget, erlang:max(?SWEEP_FLOOR, sweep())), ok
    end.

%% Answers how many entries survived. Lowered function bodies go with the
%% instance they belong to: a module has hundreds of them, so leaving them
%% behind would leak far more than the instance record itself.
sweep() ->
    Dead = [Id || {{wasm_live, Id}, T} <- get(), ets:info(T, size) =:= undefined],
    _ = [forget(Id) || Id <- Dead],
    length([K || {{wasm_live, _} = K, _} <- get()]).

forget(Id) ->
    erase({wasm_live, Id}),
    erase({wasm_inst, Id}),
    erase({wasm_mut_cache, Id}),
    case erase({wasm_entry, Id}) of
        undefined -> ok;
        Key -> erase(Key)
    end,
    forget_ir(Id).

forget_ir(Id) ->
    _ = [erase({wasm_ir, Id, Idx}) || Idx <- ir_keys(Id)],
    erase({wasm_ir_keys, Id}),
    ok.

-doc """
The functions this process has actually called, by index.

A body is lowered on first call and the indices are recorded so that releasing
the instance erases exactly those. That record is also the cheapest possible
answer to "which functions does this workload run": it is kept for a different
reason already, so asking it costs the call path nothing, where counting calls
per function would cost it on every call.

Empty for a module small enough that lowering was not deferred, which records
nothing because there was nothing to record. Read `[]` as "no information"
rather than as "nothing ran".
""".
-spec executed(#inst{}) -> [non_neg_integer()].
executed(#inst{id = Id}) -> ir_keys(Id).

ir_keys(Id) ->
    case get({wasm_ir_keys, Id}) of
        undefined -> [];
        Keys -> Keys
    end.

-doc """
The instance a `funcref` names, if this process can reach it.

`error` means a reference arrived from an instance this process has never seen
or has destroyed. That is the same situation `foreign_reference` already
describes for objects, and the caller reports it the same way rather than
guessing at an instance.
""".
-spec lookup(term()) -> {ok, #inst{}} | error.
lookup(Id) ->
    case get({wasm_inst, Id}) of
        undefined -> error;
        Inst -> {ok, Inst}
    end.

-doc "The mutable state behind a `root_view/1`, without rebuilding an instance.".
-spec mut_of(term()) -> #mut{}.
mut_of({Id, Store, Version, _Elems}) -> mut_at(Store, Version, Id).

-doc "The passive element segments in a `root_view/1`.".
-spec elems_of(term()) -> tuple().
elems_of({_Id, _Store, _Version, Elems}) -> Elems.

-doc """
Make a call's in-flight state visible to nested calls in this process.

A call reads the state once, threads it through execution and writes it back at
the end, which is what keeps a tuple update at a few nanoseconds where an ETS
write is forty. The cost is that a nested call could not see it: it read the
last committed copy, did its work, committed, and then the outer call's own
write-back discarded everything it did. Measured: a host import calling back
into its own instance allocated four objects and the outer call's return dropped
the store from four to one.

Publishing is process-local and costs nothing to a call that never re-enters:
one process-dictionary write before a host call and one after.
""".
-spec publish(#inst{}, #mut{}) -> term().
publish(#inst{id = Id}, Mut) -> put({wasm_inflight, Id}, Mut).

-doc "Undo `publish/2`, restoring whatever an enclosing call had published.".
-spec unpublish(#inst{}, term()) -> ok.
unpublish(#inst{id = Id}, undefined) -> erase({wasm_inflight, Id}), ok;
unpublish(#inst{id = Id}, Prev) -> put({wasm_inflight, Id}, Prev), ok.

-doc """
Whatever is published for this instance in this process.

The same term that was published if nothing nested wrote, and a newer one if
something did, because `set_mut/2` refreshes it. Comparing the answer with what
was published is therefore a pointer comparison that says whether a nested call
happened, which is cheaper than reading the version counter twice.
""".
-spec published(#inst{}) -> #mut{}.
published(#inst{id = Id}) -> get({wasm_inflight, Id}).

-spec set_mut(#inst{}, #mut{}) -> ok.
set_mut(#inst{store = T, version = V, id = Id}, Mut) ->
    true = ets:insert(T, {state, Mut}),
    %% If a call in this process has published its state, this commit is newer
    %% than what it published and every later nested read must see it. Without
    %% this, two nested calls in one host function would each read the outer
    %% call's snapshot and the second would lose the first's writes.
    case get({wasm_inflight, Id}) of
        undefined -> ok;
        _ -> put({wasm_inflight, Id}, Mut)
    end,
    %% Bump first, then cache at the new version: this process's own write
    %% leaves its cache valid, while any other process sees a version it does
    %% not have and reloads.
    Version = atomics:add_get(V, ?IX_VERSION, 1),
    put({wasm_mut_cache, Id}, {Version, Mut}),
    ok.

-doc """
Auxiliary per-instance state for host interfaces.

WASI needs somewhere to keep its file descriptor table that shares the
instance's lifetime. Putting it here rather than in a table of its own means
it is created and reclaimed with the instance, with no separate ownership to
get wrong.
""".
-spec get_extra(#inst{}, atom()) -> {ok, term()} | error.
get_extra(#inst{store = T}, Key) ->
    case ets:lookup(T, {extra, Key}) of
        [{_, V}] -> {ok, V};
        [] -> error
    end.

-spec set_extra(#inst{}, atom(), term()) -> ok.
set_extra(#inst{store = T}, Key, Value) ->
    true = ets:insert(T, {{extra, Key}, Value}),
    ok.

-doc """
Register something to run when this instance is destroyed.

For resources the runtime hands out but does not own: a WASI file handle or
socket is closed by whoever opened it, and dropping the reference is not the
same as closing it. Without this, an instance destroyed while the guest still
held a socket left that socket open until the owning process exited, which in a
worker resetting per request is a descriptor leaked per request.

Nothing here knows what WASI is; `wasi_preview1` registers its own.
""".
-spec on_destroy(#inst{}, fun((#inst{}) -> any())) -> ok.
on_destroy(Inst, Fun) when is_function(Fun, 1) ->
    Existing = case get_extra(Inst, cleanups) of
                   {ok, Fs} -> Fs;
                   error -> []
               end,
    set_extra(Inst, cleanups, [Fun | Existing]).

-doc "Run the registered cleanups. Called by `wasm:destroy/1`, once.".
-spec run_cleanups(#inst{}) -> ok.
run_cleanups(Inst) ->
    case get_extra(Inst, cleanups) of
        error -> ok;
        {ok, Funs} ->
            %% Cleared first, so a cleanup that calls back in cannot run twice.
            set_extra(Inst, cleanups, []),
            %% One failure must not stop the others, nor stop the pages being
            %% released: this runs on the teardown path.
            _ = [wasm_error:capture(fun() -> F(Inst) end) || F <- Funs],
            ok
    end.
