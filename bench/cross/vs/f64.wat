;; f64 arithmetic: one multiply, one add and one compare per iteration, with a
;; subtraction when the value passes 1000. Answers how many times it did.
(module
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32) (local $x f64) (local $c i32)
    (local.set $x (f64.const 1.0))
    (block $done
      (loop $top
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $x (f64.add (f64.mul (local.get $x) (f64.const 1.000001))
                               (f64.const 0.5)))
        (if (f64.gt (local.get $x) (f64.const 1000.0))
          (then (local.set $x (f64.sub (local.get $x) (f64.const 999.0)))
                (local.set $c (i32.add (local.get $c) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (local.get $c)))
