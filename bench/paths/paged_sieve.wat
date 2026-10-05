(module (memory 16)
  (func (export "sieve") (param $n i32) (result i32)
    (local $i i32) (local $j i32) (local $c i32)
    (block $d0 (loop $l0
      (br_if $d0 (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store8 (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l0)))
    (local.set $i (i32.const 2))
    (block $d1 (loop $l1
      (br_if $d1 (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.eqz (i32.load8_u (local.get $i)))
        (then
          (local.set $c (i32.add (local.get $c) (i32.const 1)))
          (if (i32.le_u (local.get $i) (i32.const 65535))
            (then
              (local.set $j (i32.mul (local.get $i) (local.get $i)))
              (block $d2 (loop $l2
                (br_if $d2 (i32.ge_u (local.get $j) (local.get $n)))
                (i32.store8 (local.get $j) (i32.const 1))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $l2)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
    (local.get $c)))
