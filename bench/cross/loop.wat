(module
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (local.get $acc) (i32.mul (local.get $i) (i32.const 3))))
        (local.set $acc (i32.xor (local.get $acc) (i32.shr_u (local.get $acc) (i32.const 7))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc)))
