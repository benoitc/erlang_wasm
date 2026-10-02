(component
  ;; Provider core: exports a function the entry core needs.
  (core module $a
    (func (export "foo") (result i32)
      (i32.const 42)))
  ;; Entry core: larger (a data blob pads it past $a), imports foo from $a,
  ;; exports run which calls it. Its import is not a WASI name, so binding by
  ;; host name alone cannot satisfy it: only core-to-core linking can.
  (core module $b
    (import "a" "foo" (func $foo (result i32)))
    (memory (export "mem") 1)
    (data (i32.const 0)
      "padding-to-make-this-core-the-largest-module-in-the-component-so-the-size-heuristic-picks-it-as-the-entry-and-its-cross-core-import-must-be-wired-by-the-linker-rather-than-a-host-function-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    (func (export "run") (result i32)
      (call $foo)))
  (core instance $ia (instantiate $a))
  (core instance $ib (instantiate $b (with "a" (instance $ia)))))
