%% -*- erlang -*-
%% Execution IR and interpreter state.

-ifndef(WASM_EXEC_HRL).
-define(WASM_EXEC_HRL, true).

%% Indices into `#inst.version', which is one `atomics' array holding both.
-define(IX_VERSION, 1).
-define(IX_CODE, 2).
%% When a compilation was last asked for, as `erlang:monotonic_time(second)`,
%% so a module that takes forty seconds to compile is asked for once and not
%% once per hot call.
%%
%% A time and not a flag, because the process that does the work can be killed
%% untrappably -- `brutal_kill` at shutdown is the ordinary case -- and no
%% `after` covers that. A flag would stay set and that instance would never ask
%% again, silently and for the life of the node. A time expires.
-define(IX_ASKED, 3).
%% How long an ask stands before another is allowed. Long enough that a real
%% compile finishes inside it, short enough that a lost one is not a life
%% sentence.
-define(ASK_RETRY_SECONDS, 60).

%% A function ready to execute. Built once at instantiation.
-record(fn, {
    nparams   = 0  :: non_neg_integer(),
    nresults  = 0  :: non_neg_integer(),
    defaults  = [] :: [term()],    % initial values for declared locals
    %% Either the execution IR, or `{lazy, Body}' holding the decoded
    %% instructions until the function is first called. Building IR for every
    %% function of a module cost 21.7 MB on a real 1.8 MB one, most of it for
    %% functions nothing ever calls, and it was paid again per instance.
    body      = [] :: [tuple() | atom()] | {lazy, [term()]},
    %% The validated body, before lowering. One word per function, pointing at
    %% the term `#module{}' already holds, so it copies nothing.
    %%
    %% Kept because the *compiler* needs a source that laziness does not change.
    %% A module below `?LAZY_THRESHOLD' is lowered up front and its `body' is
    %% fused IR by then, which cannot be unfused, and fusion exists to save the
    %% interpreter a dispatch that a compiler does not have.
    raw       = [] :: [term()],
    %% This function's index, which is what the compiled body is cached under.
    idx       = 0  :: non_neg_integer(),
    %% `{CanonicalId, #functype{}}'. Comparison is on the canonical id, because
    %% two modules number their type indices differently and a `#functype{}'
    %% mentioning `{type, 3}' means different things in each. The `#functype{}'
    %% is kept only so a mismatch can be reported in terms a reader recognises.
    type           :: term(),
    %% The `{func, NResults}' control frame, built once at instantiation rather
    %% than allocated on every call. Calls are the hot path for real compiler
    %% output (recursion dominates `fib'-shaped code), so a tuple per call is
    %% worth removing.
    frame          :: term()
}).

%% An imported function implemented in Erlang.
-record(hostfn, {
    nparams  = 0 :: non_neg_integer(),
    nresults = 0 :: non_neg_integer(),
    fun_         :: fun((term(), [term()]) -> term()),
    name         :: {binary(), binary()},
    %% As `#fn.type': `{CanonicalId, #functype{}}'. An imported function placed
    %% in a table must carry its real signature, not just its arity.
    type         :: term()
}).

%% The mutable half of an instance. Separated from the immutable half so that
%% a call reads it once, threads it functionally through execution (a tuple
%% update is a few nanoseconds; an ETS write is forty), and writes it back once
%% at the end. When instances become processes this becomes the gen_server's
%% state unchanged.
-record(mut, {
    globals   :: tuple(),          % of value()
    tables    :: tuple(),          % of tuple() of ref()
    mems      :: tuple(),          % of wasm_memory:mem()
    dropped_elems = #{} :: map(),
    dropped_datas = #{} :: map()
}).

%% The immutable half: everything derived from the module, shared by every
%% call and never written during execution.
-record(inst, {
    %% Also this instance's holder token, `{instance, Id}', on every memory it
    %% created or imported. Destroying it removes that token and nothing else,
    %% so a memory two instances share survives the first of them.
    id        :: reference(),
    %% This instance's checkpoint key in the process dictionary. A bare
    %% reference, and its own, because the key is hashed on every store
    %% mutation and on the way out of every call: a `{wasm_checkpoint, Id}'
    %% tuple had to be built and hashed each time and cost more than the write
    %% it was the key for. Nothing else in the dictionary is keyed by a bare
    %% reference, so there is nothing to collide with.
    ckpt      :: reference(),
    %% This instance's key for the cached compiled entry, and its own bare
    %% reference for the reason `ckpt` is one: the key is hashed on every call,
    %% and building a tuple to hash cost more than what it keyed.
    %%
    %% What it holds is `{Slot, Entry, Fun}`. Deriving that closure means a list
    %% walk for the module name, a tuple for the slot key and a closure
    %% allocation, all of which are fixed for as long as the instance keeps the
    %% same slot, and all of which were paid per call.
    entry_key :: undefined | reference(),
    types     :: tuple(),          % of #functype{}
    funcs     :: tuple(),          % of #fn{} | #hostfn{}
    exports   :: #{binary() => {func | table | mem | global, non_neg_integer()}},
    elems     :: tuple(),          % of [ref()] for passive segments
    datas     :: tuple(),          % of binary()
    %% Declared type of each global, so an export can carry it. A bare value
    %% cannot distinguish `(ref $t)' from `funcref', and an importer has to
    %% check that.
    globaltypes = {} :: tuple(),   % of #globaltype{}
    %% Tag identities. A tag has no mutable content, so it is immutable state:
    %% what matters is only that the same tag compares equal across modules.
    tags      = {} :: tuple(),     % of {wasm_tag, reference(), canon, functype}
    canon     = {} :: tuple(),     % of wasm_types:canon(), by type index
    %% Resolved once per module in the cached validation context: a type's
    %% fields, its kind, and its canonical supertype closure. The interpreter
    %% used to recompute all three per instruction.
    fields    = {} :: tuple(),
    kinds     = {} :: tuple(),
    supers    = {} :: tuple(),
    %% The garbage-collected object store. Structs and arrays are mutable and
    %% may refer to one another cyclically, so they cannot be ordinary Erlang
    %% terms held by their references.
    %%
    %% It sits in the *immutable* half because the handle is immutable: two ETS
    %% table ids and an `atomics' reference, fixed for the instance's life. Only
    %% what they name changes. That is the whole point. While the store was a
    %% term inside `#mut{}', every allocation and every field write changed the
    %% state term, and committing it copied the entire heap into ETS: 1993 us
    %% per mutating call at a hundred thousand objects.
    %%
    %% `undefined' when the module declares no struct or array type, which is
    %% every module that predates garbage collection.
    heap      :: undefined | wasm_heap:heap(),

    %% What names the module this instance was built from, carried through so
    %% that anything caching work derived from the module can find it. See
    %% `#module.identity'.
    identity  :: undefined | {sha256, binary()} | reference(),
    store     :: term(),           % holder for #mut{}
    %% Two counters in one `atomics' array, because an array per instance is an
    %% allocation on the instantiation path and a second one would show up in
    %% `pathbench inst_small'. `wasm_engine' names its counters the same way.
    %%
    %%   1, `?IX_VERSION': bumped on every write to `store'. Lets a reader tell
    %%      in a few nanoseconds whether its cached copy is still current,
    %%      instead of copying the state out of ETS to find out.
    %%   2, `?IX_CODE': the code slot this instance's compiled module lives in,
    %%      or zero. Written once, when compilation publishes. `#inst{}' is
    %%      immutable and learns about compiled code only after a hot call, so
    %%      the association cannot be a field holding a name -- but the array
    %%      *handle* is immutable and only what it names changes, which is the
    %%      same argument `heap' makes above.
    version   :: term(),           % atomics ref, two counters
    limits    :: map(),
    %% The validation context this module was built against, kept so a function
    %% body can be turned into IR when it is first called rather than at
    %% instantiation. It is cached per module and shared by every instance of
    %% it, so carrying it is a pointer and not a copy.
    ctx       :: term()
}).

%% Interpreter state.
%%
%% `stack' is a cons list with the top at the head, which measured faster than
%% any indexed structure. `ctrl' and `frames' are explicit rather than using
%% the Erlang call stack: Erlang has no first-class continuations, so an
%% implicit stack could not be suspended, inspected from outside, or bounded
%% independently of Erlang's own stack growth.
-record(st, {
    stack  = [] :: [term()],
    locals      :: tuple(),
    %% `toplevel' marks the outermost invocation, so returning from it
    %% terminates instead of unwinding into a caller that does not exist.
    frames = [] :: [tuple() | toplevel],
    inst        :: #inst{},
    mut         :: #mut{},
    fuel        :: non_neg_integer() | infinity,
    depth  = 0  :: non_neg_integer(),
    max_depth   :: pos_integer(),
    %% The generated module this invocation may call into, or `undefined`.
    %%
    %% Set only where a call lease is already being held for the whole
    %% invocation, which is `wasm_jit:compiled/3`'s fallback and
    %% `wasm_exec:call_out/5`. That is what lets `do_call/4` reach compiled code
    %% without taking a lease per call: no slot can be reused underneath one
    %% that is held. It is `undefined` whenever the tier is off, and whenever
    %% fuel is finite, so the call path asks one question and the dispatch path
    %% asks none.
    %%
    %% The generation as well as the name: generated code refuses a caller whose
    %% generation is not the one it was built for, which is what makes a slot
    %% safe to reuse. See `wasm_core:module/6`.
    code        :: undefined | {module(), non_neg_integer()}
}).

-endif.
