;; Recursive Fibonacci where every recursive call goes through a table.
(module
  (type $t (func (param i32) (result i32)))
  (table 1 funcref)
  (elem (i32.const 0) $fib)
  (func $fib (export "fib") (param $n i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $n) (i32.const 2))
      (then (local.get $n))
      (else (i32.add
              (call_indirect (type $t)
                (i32.sub (local.get $n) (i32.const 1)) (i32.const 0))
              (call_indirect (type $t)
                (i32.sub (local.get $n) (i32.const 2)) (i32.const 0)))))))
