;; Two components wired by a bare function rather than an interface: $C
;; imports the function "double", and the composition gives it $P's export of
;; the same name.
(component
  (component $P
    (core module $m
      (func (export "double") (param i32) (result i32)
        (i32.mul (local.get 0) (i32.const 2))))
    (core instance $i (instantiate $m))
    (func (export "double") (param "x" u32) (result u32)
      (canon lift (core func $i "double"))))
  (component $C
    (import "double" (func $double (param "x" u32) (result u32)))
    (core func $d (canon lower (func $double)))
    (core module $m
      (import "" "double" (func $double (param i32) (result i32)))
      (func (export "run") (param i32) (result i32)
        (call $double (local.get 0))))
    (core instance $i (instantiate $m (with "" (instance
      (export "double" (func $d))))))
    (func (export "run") (param "x" u32) (result u32)
      (canon lift (core func $i "run"))))
  (instance $p (instantiate $P))
  (instance $c (instantiate $C (with "double" (func $p "double"))))
  (func (export "run") (alias export $c "run")))
