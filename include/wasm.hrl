%% -*- erlang -*-
%% Core types for the decoded WebAssembly module representation.
%%
%% Design notes:
%%   * Numeric and vector types are bare atoms so that validator stack
%%     comparisons are immediate-word equality tests. Reference types are
%%     structured, because subtyping needs their parts; `pop_expect/2' still
%%     compares by equality first, so only references pay for it.
%%   * Block bodies nest directly in the AST rather than being flattened with
%%     `end' markers. WebAssembly control flow is structured, so nesting loses
%%     nothing and lets `wasm_ir' build continuation lists without a label pass.
%%   * Every name coming out of a module stays a binary. Never an atom: the atom
%%     table is node-wide and never reclaimed, so module-controlled atoms are a
%%     permanent resource leak. `wasm_decode_SUITE' asserts this.

-ifndef(WASM_HRL).
-define(WASM_HRL, true).

%%% ---------------------------------------------------------------- types ---

-type numtype()  :: i32 | i64 | f32 | f64.
-type vectype()  :: v128.

%% Reference types, in the general form the typed function references proposal
%% gives them: a nullability and a heap type.
%%
%% There is deliberately only *one* spelling of each type. `funcref' is
%% `{ref, null, func}' and nothing else, normalised at the decoder, because two
%% representations of one type is how a subtyping bug gets in. The macros below
%% are for readability at the use site, not a second representation.
%%
%% `nofunc' and `noextern' are the bottom of each hierarchy: the type of a null
%% reference before it is known what it is null *of*.
%% Three disjoint hierarchies, each with a bottom type that a null reference
%% inhabits: functions, host references, and exceptions; plus the garbage
%% collection hierarchy rooted at `any', where `eq' is what `ref.eq' compares
%% and `none' is its bottom.
-type heaptype() :: func | extern | exn
                  | any | eq | i31 | struct | array
                  | nofunc | noextern | noexn | none
                  | {type, typeidx()}.
-type reftype()  :: {ref, null | nonull, heaptype()}.
-type valtype()  :: numtype() | vectype() | reftype().

-define(FUNCREF,   {ref, null, func}).
-define(EXTERNREF, {ref, null, extern}).
-define(EXNREF,    {ref, null, exn}).

-type typeidx()   :: non_neg_integer().
-type funcidx()   :: non_neg_integer().
-type tableidx()  :: non_neg_integer().
-type memidx()    :: non_neg_integer().
-type globalidx() :: non_neg_integer().
-type elemidx()   :: non_neg_integer().
-type dataidx()   :: non_neg_integer().
-type localidx()  :: non_neg_integer().
-type labelidx()  :: non_neg_integer().

-type mut() :: const | var.

%% `max' is `undefined' when the module declares no upper bound.
%%
%% `index_type' is the memory64 proposal's addition: a memory or table may be
%% addressed by i64 instead of i32. It belongs on the limits because that is
%% where the binary format puts it, as bit 2 of the flags byte.
-record(limits, {min = 0   :: non_neg_integer(),
                 max       :: undefined | non_neg_integer(),
                 shared    = false :: boolean(),
                 index_type = i32 :: i32 | i64}).

-record(functype,   {params  = [] :: [valtype()],
                     results = [] :: [valtype()]}).

%% Composite types. A struct or array field may hold a *packed* type, narrower
%% than any value type, which is why `struct.get' comes in signed and unsigned
%% flavours: the lane has to be widened on the way out and the reader says how.
-record(fieldtype,  {type :: valtype() | i8 | i16, mut :: mut()}).
-record(structtype, {fields = [] :: [#fieldtype{}]}).
-record(arraytype,  {field :: #fieldtype{}}).

%% A declared type, as the type section actually holds it: a composite type,
%% the supertypes it declares, and whether it may be subtyped further.
%%
%% Types live in *recursive groups* so that a group's members may refer to one
%% another. `#module.rec_groups' records the boundaries as `{First, Count}',
%% because the flat list is what every index in the binary format refers to and
%% the grouping is only needed to decide type identity.
-record(subtype,    {final = true :: boolean(),
                     supers = [] :: [typeidx()],
                     body :: #functype{} | #structtype{} | #arraytype{}}).
%% `init' is the optional initialiser expression carried by the `0x40 0x00'
%% table encoding; `undefined' means the element type's default (null).
-record(tabletype,  {limits :: #limits{},
                     elemtype :: reftype(),
                     init :: undefined | [instr()]}).
-record(memtype,    {limits :: #limits{}}).
%% A tag names the type of the values an exception carries. The attribute byte
%% distinguishes exception tags from whatever later proposals add; only
%% exceptions exist so far.
-record(tagtype,    {type :: typeidx()}).
-record(globaltype, {valtype :: valtype(), mut :: mut()}).

-type externtype() :: {func,   typeidx()}
                    | {table,  #tabletype{}}
                    | {mem,    #memtype{}}
                    | {global, #globaltype{}}
                    | {tag,    #tagtype{}}.

%%% ------------------------------------------------------------ structures ---

-record(import, {module :: binary(),
                 name   :: binary(),
                 desc   :: externtype()}).

-record(export, {name :: binary(),
                 desc :: {func | table | mem | global | tag,
                          non_neg_integer()}}).

-record(global, {type :: #globaltype{},
                 init :: [instr()]}).            % constant expression

%% A body is decoded instructions until the validator has seen it, and
%% `{validated, [annotated()]}` afterwards. The two are not interchangeable and
%% the tag is what says so: only one of them carries the operand-stack heights,
%% and only one of them has been type-checked. See
%% `wasm_validate_code:function/3` for the annotation, and `strip/1` for the
%% way back.
-record(func, {type   :: typeidx(),
               locals = [] :: [valtype()],       % expanded, not run-length
               body   = [] :: [instr()] | {validated, [annotated()]}}).

%% Element segment. `mode' covers all eight binary-format variants.
-record(elem, {type :: reftype(),
               init = [] :: [[instr()]],         % one const expr per element
               mode :: passive
                     | declarative
                     | {active, tableidx(), [instr()]}}).

-record(data, {init = <<>> :: binary(),
               mode :: passive | {active, memidx(), [instr()]}}).

%% A decoded module. Sections absent from the binary leave their field empty,
%% except `start' and `data_count' which distinguish absent from zero.
-record(module, {
    %% What names this module, for anything that caches work derived from it.
    %% Two instances of one module must agree and two different modules must
    %% never agree; that is the whole contract.
    %%
    %% `{sha256, Hash}' when the caller already had the bytes hashed, which is
    %% every module that came through `wasm_module_cache', so two loads of the
    %% same bytes share whatever was derived from them. A bare `reference()'
    %% otherwise: modules built from WAT or by hand have no bytes to hash, and
    %% hashing inside `wasm:compile/1' would put five milliseconds on the
    %% 1.8 MB QuickJS path to buy sharing that the inline API does not promise.
    %% `wasm:compile/1' is documented for one-shot work; `wasm:load/1' is the
    %% one that shares.
    identity                :: undefined | {sha256, binary()} | reference(),
    types       = []        :: [#subtype{}],
    %% `{First, Count}'. A count of zero is `(rec)', an empty group, which
    %% occupies a group without declaring a type.
    rec_groups  = []        :: [{non_neg_integer(), non_neg_integer()}],
    imports     = []        :: [#import{}],
    funcs       = []        :: [#func{}],        % defined only, imports excluded
    tables      = []        :: [#tabletype{}],
    mems        = []        :: [#memtype{}],
    tags        = []        :: [#tagtype{}],
    globals     = []        :: [#global{}],
    exports     = []        :: [#export{}],
    start                   :: undefined | funcidx(),
    elems       = []        :: [#elem{}],
    datas       = []        :: [#data{}],
    data_count              :: undefined | non_neg_integer(),
    customs     = []        :: [{binary(), binary()}]
}).

%%% ---------------------------------------------------------- instructions ---

-type blocktype() :: empty | {valtype, valtype()} | {typeidx, typeidx()}.

%% Memory argument. `offset' is a u32 (u64 under memory64); `align' is the
%% log2 alignment hint, retained because it is validated against the access
%% width and because `wasm_ir' uses it to pick specialized memory paths.
-type memarg() :: {Align :: non_neg_integer(),
                   Offset :: non_neg_integer(),
                   Mem :: memidx()}.

%% Instructions are bare atoms when they carry no immediate and tuples
%% otherwise. Mixed atom/tuple dispatch compiles to an efficient jump table.
-type instr() :: atom() | tuple().

%% An instruction with the operand-stack height the validator entered it at.
%% The four instructions that contain a body carry their frame's base as well,
%% because a branch slices the stack back to the base of the frame it targets,
%% and that belongs to the frame rather than to any instruction inside it.
%%
%% The number at the head is also what tells an annotated instruction from a
%% bare one: no instruction is a tuple whose first element is an integer.
-type annotated() :: {Height :: non_neg_integer(), instr()}
                   | {Height :: non_neg_integer(),
                      Base :: non_neg_integer(), instr()}.

%%% ---------------------------------------------------------------- values ---

%% Runtime values.
%%
%% Integers are Erlang integers held in *signed* two's-complement
%% interpretation: small and negative values stay immediate words, whereas an
%% unsigned representation would turn every negative i64 into a heap bignum.
%%
%% Floats are hybrid. Erlang cannot represent NaN or Infinity as a float at all
%% (arithmetic raises badarith and `<<F:64/float>>' does not match those bit
%% patterns), so the values Erlang cannot hold get symbolic representations.
%% Signed zero needs no special case: -0.0 =/= 0.0 natively since OTP 27.
-type fspecial() :: infinity
                  | neg_infinity
                  | {nan, Sign :: 0 | 1, Payload :: non_neg_integer()}.
-type f32()      :: float() | fspecial().
-type f64()      :: float() | fspecial().
-type ref()      :: null | {funcref, non_neg_integer()} | {externref, term()}.
%% A thrown exception, as a value. `exnref' is what `catch_ref' binds and what
%% `throw_ref' re-raises, so an exception has to be an ordinary operand.
-record(exn, {tag :: term(), values = [] :: [term()]}).
-type value()    :: integer() | f32() | f64() | ref().

%%% ---------------------------------------------------------------- limits ---

-define(PAGE_SIZE, 65536).
-define(MAX_PAGES_32, 65536).           % 4 GiB, the wasm32 ceiling
%% memory64 caps at 2^48 bytes rather than the full 64-bit space, so the page
%% count stops well short of what the index type could express.
-define(MAX_PAGES_64, 281474976710656).
-define(MAX_TABLE_SIZE, 16#FFFFFFFF).
%% A 64-bit table is capped only by what its index type can express.
-define(MAX_TABLE_SIZE_64, 16#FFFFFFFFFFFFFFFF).

%% Binary-format section ids.
-define(SEC_CUSTOM,     0).
-define(SEC_TYPE,       1).
-define(SEC_IMPORT,     2).
-define(SEC_FUNCTION,   3).
-define(SEC_TABLE,      4).
-define(SEC_MEMORY,     5).
-define(SEC_GLOBAL,     6).
-define(SEC_EXPORT,     7).
-define(SEC_START,      8).
-define(SEC_ELEMENT,    9).
-define(SEC_CODE,      10).
-define(SEC_DATA,      11).
-define(SEC_DATACOUNT, 12).
-define(SEC_TAG,       13).

-endif.
