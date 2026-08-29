%% -*- erlang -*-
%% Validation context and abstract machine state.

-ifndef(WASM_VALIDATE_HRL).
-define(WASM_VALIDATE_HRL, true).

%% Index spaces are tuples rather than lists or maps: validation is dominated
%% by index lookups (every `call', `local.get' and `global.get'), and
%% `element/2' on a tuple is a single bounds-checked dereference.
-record(ctx, {
    types    = {}  :: tuple(),      % of #subtype{}
    %% Canonical identity of each type index, `{GroupId, Position}'. Two type
    %% indices name the same type exactly when these are equal, which is not
    %% the same as their declarations being structurally equal: two identical
    %% members of one recursive group are different types.
    canon    = {}  :: tuple(),      % of wasm_types:canon()
    %% Three answers about each type index that the interpreter would otherwise
    %% recompute on every instruction that asks. They belong here because the
    %% context is cached per module, so a hundred instances of one module
    %% compute them once between them.
    %%
    %%   `fields'  a tuple of `#fieldtype{}' for a struct, the single
    %%             `#fieldtype{}' for an array, `undefined' for a function.
    %%             `struct.get' read this with `lists:nth/2', so a field's cost
    %%             grew with its index.
    %%   `kinds'   `struct | array | func', for `ref.test' and `ref.cast'.
    %%   `supers'  the canonical supertype closure, which every cast recomputed
    %%             and then searched.
    fields   = {}  :: tuple(),
    kinds    = {}  :: tuple(),
    supers   = {}  :: tuple(),
    funcs    = {}  :: tuple(),      % of typeidx(), imports first
    tables   = {}  :: tuple(),      % of #tabletype{}
    mems     = {}  :: tuple(),      % of #memtype{}
    globals  = {}  :: tuple(),      % of #globaltype{}
    tags     = {}  :: tuple(),      % of #tagtype{}
    elems    = {}  :: tuple(),      % of reftype()
    n_datas  = 0   :: non_neg_integer(),
    %% Globals importable by a constant expression: only imported ones are in
    %% scope for `global.get' in an initialiser.
    n_imported_globals = 0 :: non_neg_integer(),
    %% Function indices that may appear in `ref.func'. A function is only
    %% referenceable if it is exported, appears in an element segment, or is
    %% named by a declarative segment. Without this set, `ref.func' would let a
    %% module forge a reference to any function including ones the embedder
    %% never exposed.
    refs     = #{} :: #{non_neg_integer() => true},
    %% Globals that are shared state rather than a per-instance value: mutable
    %% *and* either imported or exported, which is exactly when another module
    %% can observe a write. `wasm_instance' resolves this into the instruction
    %% when the IR is built, so an ordinary `global.get' stays a tuple read.
    shared_globals = #{} :: #{non_neg_integer() => true},
    %% Memories another instance can observe growing: imported or exported.
    %% Only these pay for a published page count.
    shared_mems = #{} :: #{non_neg_integer() => true},
    %% Per-function state.
    locals   = {}  :: tuple(),      % of valtype(), params then declared locals
    results  = []  :: [valtype()]   % current function's result types
}).

%% One entry per structured control construct currently open.
-record(ctrl, {
    opcode      :: block | loop | if_ | else_ | func,
    start_types = [] :: [valtype()],
    end_types   = [] :: [valtype()],
    height      = 0  :: non_neg_integer(),
    %% Locals initialised when this frame was entered. A local assigned inside
    %% a frame reverts to uninitialised when the frame ends: only one arm of an
    %% `if' runs, and a `block' may be branched out of before its assignments
    %% happen. The specification is deliberately this conservative.
    inited      = #{} :: #{non_neg_integer() => true},
    %% Set once the rest of the block is statically unreachable. While set, the
    %% operand stack is polymorphic: popping past the frame height yields
    %% `unknown' instead of failing. Modelling this explicitly is what makes
    %% code after `br'/`unreachable' validate correctly, and getting it wrong
    %% is the classic validator bug in both directions.
    unreachable = false :: boolean()
}).

%% Abstract interpreter state. `opds' is a list with the stack top at the head;
%% `nopds' tracks its length so frame-height comparisons stay O(1).
-record(vs, {
    opds  = [] :: [valtype() | unknown],
    nopds = 0  :: non_neg_integer(),
    ctrls = [] :: [#ctrl{}],
    %% Which locals are known to hold a value. Only consulted for locals whose
    %% type has no default, which is to say non-nullable references.
    inited = #{} :: #{non_neg_integer() => true},
    ctx        :: #ctx{},
    %% Where a control instruction hands its annotated body back to `instrs/2'.
    %% Only the four instructions that contain a body ever set it, and `instrs/2'
    %% clears it before each instruction, so `undefined' means "not a control
    %% instruction" rather than "nothing to say".
    ann = undefined :: undefined | tuple()
}).

-endif.
