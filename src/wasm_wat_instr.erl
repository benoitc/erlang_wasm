-module(wasm_wat_instr).
-moduledoc """
What immediate an instruction takes, by name. Add a text-format instruction
here if, and only if, it carries an immediate.

There are around four hundred instructions and only about seventy carry an
immediate, so this table holds those seventy and nothing else. Everything absent
from it is a plain instruction whose atom is its name with the dots replaced:
`i32.add` is `i32_add`, `i64.trunc_sat_f32_u` is `i64_trunc_sat_f32_u`.

That is not a shortcut around knowing the instruction set. The validator is
already the authority on which atoms are instructions and answers
`unknown_operator` for the rest, so a parser that also kept a list of the four
hundred would be a second copy to disagree with the first. What the parser has
to know, and the validator cannot tell it, is how many *tokens* to consume.

The memory instructions are recognised by asking the tables the validator and
the interpreter already share, so a memory argument is never a name this module
has to keep in step by hand.
""".

-export([immediate/1, atom_of/1]).

-doc """
The immediate an instruction takes, or `plain` if it takes none.

| answer | means |
| --- | --- |
| `plain` | no immediate |
| `{const, Type}` | a numeric literal |
| `{idx, Space}` | one index, named or numeric |
| `{idx_opt, Space}` | one index that defaults to 0 when absent |
| `{idx2, A, B}` | two indices, both required |
| `{copy2, Space}` | two indices that default to 0 and 0 together |
| `{init2, Space, Segment}` | an optional space index then a segment index |
| `{memarg, Natural}` | `offset=` and `align=`, both optional |
| `{memarg_lane, Natural, Count}` | a memory argument and a lane index |
| `{lane, Count}` | a lane index |
| `block` | a block type and a body |
| `call_indirect` | an optional table index and a type use |
| `br_table` | a vector of labels and a default |
| `select` | an optional result type |
| `heaptype` / `reftype` | for `ref.null` and the casts |
| `br_on_cast` | a label and two reference types |
| `shuffle` | sixteen lane indices |
| `v128const` | a shape and its lanes |

`Natural` is the alignment a missing `align=` means, in log2 bytes. It comes
from the validator's own tables, which is why the text format cannot drift from
what validation then checks the number against.
""".
-spec immediate(binary()) -> term().

%%% ---------------------------------------------------------- control flow ---

immediate(<<"block">>) -> block;
immediate(<<"loop">>) -> block;
immediate(<<"if">>) -> block;
immediate(<<"try_table">>) -> block;
immediate(<<"br">>) -> {idx, label};
immediate(<<"br_if">>) -> {idx, label};
immediate(<<"br_table">>) -> br_table;
immediate(<<"br_on_null">>) -> {idx, label};
immediate(<<"br_on_non_null">>) -> {idx, label};
immediate(<<"br_on_cast">>) -> br_on_cast;
immediate(<<"br_on_cast_fail">>) -> br_on_cast;
immediate(<<"call">>) -> {idx, func};
immediate(<<"return_call">>) -> {idx, func};
immediate(<<"call_ref">>) -> {idx, type};
immediate(<<"return_call_ref">>) -> {idx, type};
immediate(<<"call_indirect">>) -> call_indirect;
immediate(<<"return_call_indirect">>) -> call_indirect;
immediate(<<"throw">>) -> {idx, tag};
immediate(<<"select">>) -> select;

%%% ------------------------------------------------------------ variables ---

immediate(<<"local.get">>) -> {idx, local};
immediate(<<"local.set">>) -> {idx, local};
immediate(<<"local.tee">>) -> {idx, local};
immediate(<<"global.get">>) -> {idx, global};
immediate(<<"global.set">>) -> {idx, global};

%%% --------------------------------------------------------------- tables ---

%% Every table instruction may leave its index out and mean table 0, which is
%% how every module written before the reference types proposal is spelled.
immediate(<<"table.get">>) -> {idx_opt, table};
immediate(<<"table.set">>) -> {idx_opt, table};
immediate(<<"table.size">>) -> {idx_opt, table};
immediate(<<"table.grow">>) -> {idx_opt, table};
immediate(<<"table.fill">>) -> {idx_opt, table};
immediate(<<"table.copy">>) -> {copy2, table};
immediate(<<"table.init">>) -> {init2, table, elem};
immediate(<<"elem.drop">>) -> {idx, elem};

%%% -------------------------------------------------------------- memories ---

immediate(<<"memory.size">>) -> {idx_opt, memory};
immediate(<<"memory.grow">>) -> {idx_opt, memory};
immediate(<<"memory.fill">>) -> {idx_opt, memory};
immediate(<<"memory.copy">>) -> {copy2, memory};
immediate(<<"memory.init">>) -> {init2, memory, data};
immediate(<<"data.drop">>) -> {idx, data};

%%% ------------------------------------------------------------- constants ---

immediate(<<"i32.const">>) -> {const, i32};
immediate(<<"i64.const">>) -> {const, i64};
immediate(<<"f32.const">>) -> {const, f32};
immediate(<<"f64.const">>) -> {const, f64};
immediate(<<"v128.const">>) -> v128const;

%%% ------------------------------------------------------------ references ---

immediate(<<"ref.null">>) -> heaptype;
immediate(<<"ref.func">>) -> {idx, func};
immediate(<<"ref.test">>) -> reftype;
immediate(<<"ref.cast">>) -> reftype;

%%% ----------------------------------------------------- garbage collection ---

immediate(<<"struct.new">>) -> {idx, type};
immediate(<<"struct.new_default">>) -> {idx, type};
immediate(<<"struct.get">>) -> {idx2, type, field};
immediate(<<"struct.get_s">>) -> {idx2, type, field};
immediate(<<"struct.get_u">>) -> {idx2, type, field};
immediate(<<"struct.set">>) -> {idx2, type, field};
immediate(<<"array.new">>) -> {idx, type};
immediate(<<"array.new_default">>) -> {idx, type};
immediate(<<"array.new_fixed">>) -> {idx2, type, u32};
immediate(<<"array.new_data">>) -> {idx2, type, data};
immediate(<<"array.new_elem">>) -> {idx2, type, elem};
immediate(<<"array.get">>) -> {idx, type};
immediate(<<"array.get_s">>) -> {idx, type};
immediate(<<"array.get_u">>) -> {idx, type};
immediate(<<"array.set">>) -> {idx, type};
immediate(<<"array.fill">>) -> {idx, type};
immediate(<<"array.copy">>) -> {idx2, type, type};
immediate(<<"array.init_data">>) -> {idx2, type, data};
immediate(<<"array.init_elem">>) -> {idx2, type, elem};

%%% --------------------------------------------------------------- vectors ---

immediate(<<"i8x16.shuffle">>) -> shuffle;

%%% ---------------------------------------------------- everything by shape ---

%% Anything left is a plain instruction unless one of the tables the validator
%% and interpreter share says it touches memory or a lane. Asking them rather
%% than listing the names here is what keeps a memory argument from being a
%% third place that has to agree with the other two.
immediate(Name) ->
    Atom = atom_of(Name),
    case wasm_validate_simd:lane_mem_op(Atom) of
        {_, Natural, Count} -> {memarg_lane, Natural, Count};
        false -> by_lane(Atom)
    end.

by_lane(Atom) ->
    case wasm_validate_simd:lane_op(Atom) of
        {Count, _, _} -> {lane, Count};
        false -> by_memory(Atom)
    end.

%% `load_store/1' answers for the vector loads and stores too, so this covers
%% every non-atomic memory access there is.
by_memory(Atom) ->
    case wasm_validate_code:load_store(Atom) of
        {_, _, Natural} -> {memarg, Natural};
        false -> by_atomic(Atom)
    end.

%% An atomic access states its width in bytes rather than log2, because that is
%% what its validation rule compares against.
by_atomic(Atom) ->
    case wasm_validate_atomic:mem_op(Atom) of
        {_, _, Bytes} -> {memarg, log2(Bytes)};
        false -> plain
    end.

log2(1) -> 0;
log2(2) -> 1;
log2(4) -> 2;
log2(8) -> 3.

-doc """
The atom an instruction name denotes: the name with its dots replaced.

`i32.add` is `i32_add` and `i64.atomic.rmw8.add_u` is `i64_atomic_rmw8_add_u`.
Existing atoms only: a name that denotes no instruction stays a binary and is
reported where it is used, rather than adding an atom the module chose. The
atom table is node-wide and never reclaimed, so a module that could create
atoms is a permanent resource leak.
""".
-spec atom_of(binary()) -> atom() | binary().
atom_of(Name) ->
    Underscored = binary:replace(Name, <<".">>, <<"_">>, [global]),
    try binary_to_existing_atom(Underscored, utf8)
    catch error:badarg -> Name
    end.
