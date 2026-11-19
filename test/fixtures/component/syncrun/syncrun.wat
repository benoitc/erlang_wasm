;; A `wasi:cli/run' whose `run' is an async function lifted without the async
;; option, as wasi-libc with cooperative threads lifts it: the whole task is
;; one core call, and its result comes back flat.
(component
  (core module $m
    (func (export "run") (result i32) (i32.const 0)))
  (core instance $i (instantiate $m))
  (type $r (result))
  (type $f (func async (result $r)))
  (func $run (type $f) (canon lift (core func $i "run")))
  (instance $run-instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run-instance)))
