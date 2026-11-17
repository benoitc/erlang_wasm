;; A component defining a resource, for `wasm_component_snapshot_SUITE'.
;; `init' makes one, drops it, makes a second and keeps its handle in a global;
;; `held-rep' reads that one's representation; `fresh' makes and drops a third
;; and answers its handle, which must be one the guest never saw before.
(component
  (type $r (resource (rep i32)))
  (core func $new (canon resource.new $r))
  (core func $rep (canon resource.rep $r))
  (core func $drop (canon resource.drop $r))
  (core module $m
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (global $held (mut i32) (i32.const 0))
    (func (export "init") (local $h i32)
      (local.set $h (call $new (i32.const 10)))
      (call $drop (local.get $h))
      (global.set $held (call $new (i32.const 20))))
    (func (export "held-rep") (result i32) (call $rep (global.get $held)))
    (func (export "fresh") (result i32) (local $h i32)
      (local.set $h (call $new (i32.const 30)))
      (call $drop (local.get $h))
      (local.get $h)))
  (core instance $i (instantiate $m (with "" (instance
    (export "new" (func $new)) (export "rep" (func $rep)) (export "drop" (func $drop))))))
  (func (export "init") (canon lift (core func $i "init")))
  (func (export "held-rep") (result u32) (canon lift (core func $i "held-rep")))
  (func (export "fresh") (result u32) (canon lift (core func $i "fresh"))))
