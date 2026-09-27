;; Non-vacuous string-encoding=utf16 fixtures. `units` returns the length operand the
;; runtime passes after lowering the string, which is the count of UTF-16 code units
;; (differs from the UTF-8 byte count), exercising the lower. `make` returns a constant
;; string whose bytes at offset 100 are UTF-16LE "café", exercising the lift (read as
;; UTF-8 they would be invalid). The guest does not interpret the bytes itself.
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 100) "\63\00\61\00\66\00\e9\00")
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
      (memory $mi "memory") (realloc (func $mi "cabi_realloc")) string-encoding=utf16))
  (func (export "make") (result string)
    (canon lift (core func $mi "make")
      (memory $mi "memory") (realloc (func $mi "cabi_realloc")) string-encoding=utf16)))
