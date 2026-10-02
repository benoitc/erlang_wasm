(component
 (core module $m
  (memory (export "mem") 1)
  (func (export "allocate") (param i32 i32 i32 i32) (result i32) i32.const 32)
  (func (export "run") (param i32 i32) (result i32) local.get 1))
 (core instance $i (instantiate $m))
 (func (export "run") (param "s" string) (result u32) (canon lift (core func $i "run") (memory $i "mem") (realloc (func $i "allocate")))))
