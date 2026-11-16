;; Two async lifts whose core types follow the async rule of the Canonical
;; ABI, not the sync one: a callback lift returns its status (i32) whatever
;; the function returns, and a stackful lift returns nothing, its result going
;; through task.return. Each would fail a check that applies the sync rule.
(component
  (core module $m
    (import "" "task.return" (func $ret (param i32)))
    (func (export "callback-none") (result i32) (i32.const 0))
    (func (export "callback") (param i32 i32 i32) (result i32) (i32.const 0))
    (func (export "stackful-u32") (call $ret (i32.const 7))))
  (core func $ret (canon task.return (result u32)))
  (core instance $i (instantiate $m (with "" (instance
    (export "task.return" (func $ret))))))
  (func (export "callback-none") async
    (canon lift (core func $i "callback-none") async
      (callback (core func $i "callback"))))
  (func (export "stackful-u32") async (result u32)
    (canon lift (core func $i "stackful-u32") async)))
