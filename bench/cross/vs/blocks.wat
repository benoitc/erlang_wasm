;; An i32 loaded from memory and an i32 taken from a block result, per
;; iteration, over a 64 KiB window.
(module
  (memory (export "memory") 1)
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32) (local $acc i32) (local $a i32) (local $v i32) (local $r i32)
    (block $done
      (loop $top
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $a (i32.and (i32.shl (local.get $i) (i32.const 2))
                               (i32.const 65532)))
        (local.set $v (i32.load (local.get $a)))
        (local.set $r
          (block $b (result i32)
            (drop (br_if $b (i32.add (local.get $v) (local.get $i))
                            (i32.lt_u (local.get $v) (i32.const 1000000))))
            (i32.xor (local.get $v) (i32.const -1))))
        (i32.store (local.get $a) (local.get $r))
        (local.set $acc (i32.xor (local.get $acc) (local.get $r)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (local.get $acc)))
