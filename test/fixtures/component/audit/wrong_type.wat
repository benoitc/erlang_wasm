;; Two resource types. The guest mints a handle of type $a, then calls
;; resource.rep for type $b on it. A handle of one resource type used where
;; another is expected must trap, not return a representation.
(component
  (type $a (resource (rep i32)))
  (type $b (resource (rep i32)))
  (core func $newa (canon resource.new $a))
  (core func $repb (canon resource.rep $b))
  (core module $m
    (import "r" "newa" (func $newa (param i32) (result i32)))
    (import "r" "repb" (func $repb (param i32) (result i32)))
    (func (export "run") (result i32)
      i32.const 7 call $newa
      call $repb))
  (core instance $mi
    (instantiate $m
      (with "r" (instance (export "newa" (func $newa)) (export "repb" (func $repb))))))
  (func (export "run") (result u32) (canon lift (core func $mi "run"))))
