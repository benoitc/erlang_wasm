(component
 (core module $m
  (global $n (mut i32) (i32.const 0))
  (func (export "run") (result i32) global.get $n)
  (func (export "cleanup") (param i32) i32.const 1 global.set $n))
 (core instance $i (instantiate $m))
 (func (export "run") (result u32) (canon lift (core func $i "run") (post-return (func $i "cleanup")))))
