(component
 (type $r (resource (rep i32)))
 (core func $new (canon resource.new $r))
 (core func $drop (canon resource.drop $r))
 (core module $m
  (import "r" "[resource-new]r" (func $new (param i32) (result i32)))
  (import "r" "[resource-drop]r" (func $drop (param i32)))
  (func (export "run") (result i32) (local $h i32)
   i32.const 7 call $new local.tee $h call $drop
   local.get $h call $drop i32.const 42))
 (core instance $r (export "[resource-new]r" (func $new)) (export "[resource-drop]r" (func $drop)))
 (core instance $i (instantiate $m (with "r" (instance $r))))
 (func (export "run") (result u32) (canon lift (core func $i "run"))))
