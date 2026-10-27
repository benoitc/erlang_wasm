;; n copies of 4 KiB with memory.copy; returns a byte of the result.
(module
  (memory (export "memory") 1)
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32)
    (i32.store8 (i32.const 100) (i32.const 7))
    (block $done
      (loop $top
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (memory.copy (i32.const 8192) (i32.const 0) (i32.const 4096))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (i32.add (local.get $i) (i32.load8_u (i32.const 8292)))))
