(component
 (core module $a (func (export "run") (result i32) i32.const 99) (memory 1) (data (i32.const 0) "padding makes this core larger than the actual exported one"))
 (core module $b (func (export "run") (result i32) i32.const 42))
 (core instance $ai (instantiate $a))
 (core instance $bi (instantiate $b))
 (func (export "run") (result u32) (canon lift (core func $bi "run"))))
