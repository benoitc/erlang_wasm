(component
  ;; Provider core: exports a function the entry core needs. It instantiates
  ;; cleanly, so the linker builds it first.
  (core module $a
    (func (export "foo") (result i32)
      (i32.const 42)))
  ;; Entry core: larger (a data blob pads it past $a), imports foo from $a, and
  ;; traps in its start function. Instantiating it fails, but only after $a is
  ;; already built, so the linker has a live core to free on the error path.
  (core module $b
    (import "a" "foo" (func $foo (result i32)))
    (memory (export "mem") 1)
    (data (i32.const 0)
      "padding-to-make-this-core-the-largest-module-in-the-component-so-the-size-heuristic-picks-it-as-the-entry-and-its-start-function-runs-during-instantiation-and-traps-after-the-provider-core-has-already-been-built-xxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    (func $start
      (unreachable))
    (start $start)
    (func (export "run") (result i32)
      (call $foo)))
  (core instance $ia (instantiate $a))
  (core instance $ib (instantiate $b (with "a" (instance $ia)))))
