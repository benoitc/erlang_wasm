;; For `wasm_component_SUITE': a resource whose destructor is declared in a
;; second type section. `$u' is in the first section; the core module and
;; instance between them make the encoder start a new section for `$r', which
;; is type 1 of the component's type space. `make-and-drop' makes a handle and
;; drops it, which must run the destructor; `count' answers how many times it
;; ran.
(component
  (type $u (func (result u32)))
  (core module $d
    (global $n (mut i32) (i32.const 0))
    (func (export "dtor") (param i32)
      (global.set $n (i32.add (global.get $n) (i32.const 1))))
    (func (export "count") (result i32) (global.get $n)))
  (core instance $di (instantiate $d))
  (core func $dtor (alias core export $di "dtor"))
  (type $r (resource (rep i32) (dtor (func $dtor))))
  (core func $new (canon resource.new $r))
  (core func $drop (canon resource.drop $r))
  (core module $m
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (func (export "make-and-drop")
      (call $drop (call $new (i32.const 7)))))
  (core instance $mi (instantiate $m (with "" (instance
    (export "new" (func $new)) (export "drop" (func $drop))))))
  (func (export "make-and-drop") (canon lift (core func $mi "make-and-drop")))
  (func (export "count") (type $u) (canon lift (core func $di "count"))))
