(module (memory (export "m") 16)
  (func (export "run") (param $n i32) (local $i i32)
    (loop $l
      (i32.store (i32.and (i32.shl (local.get $i) (i32.const 2)) (i32.const 65532))
                 (local.get $i))
      (i64.store offset=65536
                 (i32.and (i32.shl (local.get $i) (i32.const 3)) (i32.const 65528))
                 (i64.extend_i32_u (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))))
