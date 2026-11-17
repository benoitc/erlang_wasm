;; Two cores, for `wasm_component_snapshot_SUITE'. $A, built first, defines a
;; table, a mutable funcref global and a mutable counter it exports; $B, built
;; after it, imports all three. `setup' puts $B's `seven' into $A's table and
;; global: references to a core built later. `seven' bumps the counter $B
;; imports, which `count' reads through $A.
(component
  (core module $A
    (type $t (func (result i32)))
    (table (export "tab") 2 funcref)
    (global $g (export "g") (mut funcref) (ref.null func))
    (global $n (export "n") (mut i32) (i32.const 0))
    (func (export "via-table") (result i32)
      (call_indirect (type $t) (i32.const 0)))
    (func (export "via-global") (result i32)
      (table.set (i32.const 1) (global.get $g))
      (call_indirect (type $t) (i32.const 1)))
    (func (export "count") (result i32) (global.get $n)))
  (core instance $a (instantiate $A))
  (core module $B
    (import "a" "tab" (table 2 funcref))
    (import "a" "g" (global $g (mut funcref)))
    (import "a" "n" (global $n (mut i32)))
    (func $seven (result i32)
      (global.set $n (i32.add (global.get $n) (i32.const 1)))
      (i32.const 7))
    (elem declare func $seven)
    (func (export "setup")
      (table.set (i32.const 0) (ref.func $seven))
      (global.set $g (ref.func $seven))))
  (core instance $b (instantiate $B (with "a" (instance $a))))
  (func (export "setup") (canon lift (core func $b "setup")))
  (func (export "via-table") (result u32) (canon lift (core func $a "via-table")))
  (func (export "via-global") (result u32) (canon lift (core func $a "via-global")))
  (func (export "count") (result u32) (canon lift (core func $a "count"))))
