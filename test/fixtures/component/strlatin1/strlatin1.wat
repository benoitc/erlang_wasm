;; Non-vacuous string-encoding=latin1+utf16 fixtures. `units` returns the length operand
;; after lowering: for a Latin-1-representable string it is the byte count with the high
;; bit clear; for one needing UTF-16 it is the code-unit count with the high bit set.
;; `make` returns a constant Latin-1 "café" (bytes at offset 100), which the lift widens.
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 100) "\63\61\66\e9")
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 16)
    (func (export "units") (param i32 i32) (result i32)
      local.get 1)
    (func (export "make") (result i32)
      (i32.store (i32.const 8) (i32.const 100))
      (i32.store (i32.const 12) (i32.const 4))
      i32.const 8))
  (core instance $mi (instantiate $m))
  (func (export "units") (param "s" string) (result u32)
    (canon lift (core func $mi "units")
      (memory $mi "memory") (realloc (func $mi "cabi_realloc"))
      string-encoding=latin1+utf16))
  (func (export "make") (result string)
    (canon lift (core func $mi "make")
      (memory $mi "memory") (realloc (func $mi "cabi_realloc"))
      string-encoding=latin1+utf16)))
