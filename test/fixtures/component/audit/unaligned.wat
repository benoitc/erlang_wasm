(component
 (core module $m (memory (export "memory") 1)
  (data (i32.const 1) "\01\00\00\00\02\00\00\00")
  (func (export "run") (result i32) i32.const 1))
 (core instance $i (instantiate $m))
 (type $t (tuple u32 u32))
 (func (export "run") (result $t) (canon lift (core func $i "run") (memory $i "memory"))))
