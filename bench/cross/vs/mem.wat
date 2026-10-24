;; One i32.store and one i32.load per iteration, over a 64 KiB window.
(module
  (memory (export "memory") 1)
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32) (local $acc i32) (local $a i32)
    (block $done
      (loop $top
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $a (i32.and (i32.shl (local.get $i) (i32.const 2))
                               (i32.const 65532)))
        (i32.store (local.get $a) (i32.add (local.get $i) (local.get $acc)))
        (local.set $acc (i32.xor (local.get $acc) (i32.load (local.get $a))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (local.get $acc)))
