# Adding an instruction

This is the change you will make most often, and the files you touch depend on
which opcode space the instruction lives in. Use this page when a proposal adds
an instruction, or when one is already decoded but traps as unimplemented.

Every instruction is an atom whose name is the text-format name with the dots
replaced: `i32.add` is `i32_add`, `i64.trunc_sat_f32_u` is
`i64_trunc_sat_f32_u`. That atom is the only thing the four stages share.

## The four stages

Every instruction passes through the same four, in this order:

| stage | question | where |
| --- | --- | --- |
| decode | which bytes mean this instruction | `wasm_decode_*` |
| validate | what it takes off the stack and puts back | `wasm_validate_*` |
| interpret | what it computes | `wasm_exec`, or a helper module |
| compile | how to say that in Core Erlang | `wasm_core`, optional |

The compile stage is optional. An instruction the generator does not know is
left to the interpreter, and the tier keeps working. Adding one there is a
performance change, not a correctness one.

The text format is usually free. `wasm_wat_instr` only lists the seventy or so
instructions that carry an **immediate**; anything else is derived from the
atom. Add an entry only if yours takes an immediate.

## A plain numeric instruction

`i64.extend8_s` is the model. Four files, one line each.

```erlang
%% src/wasm_decode_code.erl -- the opcode
instr(16#C2, R) -> {i64_extend8_s, R};

%% src/wasm_validate_code.erl -- the stack effect
numeric(i64_extend8_s) -> {[i64], [i64]};

%% src/wasm_exec.erl -- what it computes
unop(i64_extend8_s, A) -> wasm_num:wrap_s64(sign_extend(1, A band 16#FF));

%% src/wasm_core.erl -- optional, to let the tier compile it
%% add the atom to the supported list; it then routes through wasm_exec:op1/2
```

Note the last one. Adding an atom to `wasm_core:supported/1` is enough to make
the tier accept the instruction, because an operation with no inline form is
generated as a call to `wasm_exec:op1/2` or `op2/3`. Writing an inline form in
`wasm_core`'s private `inline/1` table is a further, separate optimisation.

## A SIMD instruction, the `0xFD` space

Three files, and none of them is `wasm_exec`.

```erlang
%% src/wasm_decode_simd.erl -- the sub-opcode
sub(186, R) -> {i32x4_dot_i16x8_s, R};

%% src/wasm_validate_simd.erl -- operand types
type_of(i32x4_dot_i16x8_s) -> {[v128, v128], [v128]};

%% src/wasm_simd.erl -- the operation
binary_op(i32x4_dot_i16x8_s, A, B) -> ...
```

`wasm_exec` reaches these through `wasm_simd` and needs no clause of its own.

## A GC instruction, the `0xFB` space

```erlang
%% src/wasm_decode_gc.erl
sub(22, R0) -> cast(ref_cast, nonull, R0);

%% src/wasm_validate_code.erl -- not a separate module: casts are typed
%% against the type hierarchy, which lives with the rest of validation
instr({ref_cast, Target}, S0) -> ...

%% src/wasm_exec.erl -- these carry an immediate, so they match in run/3
%% rather than going through unop/binop
run([{ref_cast, Target} | Rest], Ctrl, #st{stack = [R | _]} = St) -> ...
```

## An atomic instruction, the `0xFE` space

`wasm_decode_atomic` and `wasm_validate_atomic`, then `wasm_exec` or
`wasm_wait` depending on whether it waits.

## The test to write

One per stage you touched, and in this order.

1. **The specification suite, first.** Find the upstream suite that covers your
   instruction and check it is in `wasm_spec_manifest:core/0`. If your change
   makes a previously failing suite pass, tighten `wasm_spec_SUITE`'s baseline
   in the same commit: a baseline that has become too generous fails the build
   on purpose.
2. **The compiled path, if you touched `wasm_core`.**
   `wasm_spec_SUITE:compiled_phase` runs the whole suite through generated
   code, so it covers you for free. Check its counts moved.
3. **A differential case** in `test/wasm_core_SUITE.erl` if the instruction has
   an inline form. Generated and interpreted must agree on values chosen to
   catch a wrong width or a missing sign extension: the sign bit of each width,
   all ones, and zero. `i32.shr_u` was wrong for exactly one input class,
   a masked shift count of zero, and every other input hid it.
4. **A hand-written case** only for behaviour the specification suite does not
   reach, such as an interaction with limits or with the host.

## Checking what you generated

If you added an inline form, look at it:

```erlang
{ok, I} = wasm:instantiate(M, #{}, #{}),
io:format("~s~n", [wasm_jit:dump(I)]).
```

`wasm_jit:dump/2` takes a function index when the module is large. See
[the compiled tier](compiled-tier.md).

## Short notes

- The validator is the authority on which atoms exist. It answers
  `unknown_operator` for anything else, which is why the text parser does not
  keep its own list.
- Adding an atom to `wasm_core:supported/1` without an implementation in
  `wasm_exec:op1/2` or `op2/3` is caught by
  `wasm_core_SUITE:every_supported_operation_reaches_an_implementation`.
- If the instruction touches memory, `wasm_exec:load_spec/1` and `store_spec/1`
  are read by `wasm_core` at generation time. Change the spec, not both paths.
- If you find yourself adding a module, read [architecture](architecture.md)
  first and decide its level.
