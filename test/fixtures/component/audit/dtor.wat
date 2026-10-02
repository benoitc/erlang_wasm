;; A resource whose destructor increments a counter the guest can read back.
;; `run` mints a handle, drops it, then returns the destructor-call count: it is
;; 1 only if dropping the owned handle ran the destructor exactly once.
(component
  ;; The destructor lives in its own core module (no resource imports) so it can
  ;; be referenced by the resource type without an instantiation cycle.
  (core module $d
    (global $count (mut i32) (i32.const 0))
    (func (export "dtor") (param i32)
      global.get $count i32.const 1 i32.add global.set $count)
    (func (export "count") (result i32) global.get $count))
  (core instance $di (instantiate $d))
  (alias core export $di "dtor" (core func $dtor))
  (type $r (resource (rep i32) (dtor $dtor)))
  (core func $rnew (canon resource.new $r))
  (core func $rdrop (canon resource.drop $r))
  (core module $m
    (import "r" "new" (func $new (param i32) (result i32)))
    (import "r" "drop" (func $drop (param i32)))
    (import "d" "count" (func $count (result i32)))
    (func (export "run") (result i32)
      i32.const 7 call $new call $drop
      call $count))
  (core instance $mi
    (instantiate $m
      (with "r" (instance (export "new" (func $rnew)) (export "drop" (func $rdrop))))
      (with "d" (instance (export "count" (func $di "count"))))))
  (func (export "run") (result u32) (canon lift (core func $mi "run"))))
