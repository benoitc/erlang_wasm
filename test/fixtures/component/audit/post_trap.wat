(component
 (core module $m
  (func (export "run") (result i32) i32.const 42)
  (func (export "cabi_post_run") (param i32) unreachable))
 (core instance $i (instantiate $m))
 (func (export "run") (result u32) (canon lift (core func $i "run") (post-return (func $i "cabi_post_run")))))
