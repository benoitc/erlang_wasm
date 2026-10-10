(module (memory (export "m") 16)
  ;; every word non-zero, so a capture has content on every page
  (func (export "init") (param $n i32) (result i32) (local $a i32)
    (loop $l
      (i64.store (local.get $a) (i64.const 0x0101010101010101))
      (local.set $a (i32.add (local.get $a) (i32.const 8)))
      (br_if $l (i32.lt_u (local.get $a) (i32.const 1048576))))
    (i32.const 0))
  ;; first write to k pages from base
  (func (export "touch") (param $base i32) (param $k i32) (result i32) (local $p i32)
    (loop $l
      (i32.store (i32.add (local.get $base) (i32.shl (local.get $p) (i32.const 12))) (i32.const 7))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $p) (local.get $k))))
    (i32.const 0))
  ;; n loads cycling over 3 addresses `stride' apart from base
  (func (export "ld") (param $n i32) (param $stride i32) (param $base i32) (result i32)
    (local $i i32) (local $s i32)
    (loop $l
      (local.set $s (i32.add (local.get $s)
        (i32.load (i32.add (local.get $base)
          (i32.add (i32.mul (i32.rem_u (local.get $i) (i32.const 3)) (local.get $stride))
                   (i32.and (i32.shl (local.get $i) (i32.const 3)) (i32.const 2040)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $s))
  (func (export "st") (param $n i32) (param $stride i32) (param $base i32) (result i32)
    (local $i i32)
    (loop $l
      (i32.store (i32.add (local.get $base)
          (i32.add (i32.mul (i32.rem_u (local.get $i) (i32.const 3)) (local.get $stride))
                   (i32.and (i32.shl (local.get $i) (i32.const 3)) (i32.const 2040))))
        (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $i)))
