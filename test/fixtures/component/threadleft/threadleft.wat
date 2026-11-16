;; `run' starts a thread, switches to it, and the thread suspends: `run'
;; returns 7 with the thread still suspended, and its process alive until the
;; instance is destroyed.
(component
  (core module $libc (table (export "t") 1 funcref))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "t" (core table $t))
  (core type $ft (func (param i32)))
  (core func $new (canon thread.new-indirect $ft (core table $t)))
  (core func $ytr (canon thread.yield-then-resume))
  (core func $suspend (canon thread.suspend))
  (core module $m
    (import "" "new" (func $new (param i32 i32) (result i32)))
    (import "" "ytr" (func $ytr (param i32) (result i32)))
    (import "" "suspend" (func $suspend (result i32)))
    (import "" "t" (table 1 funcref))
    (func $start (param i32) (drop (call $suspend)))
    (elem (i32.const 0) $start)
    (func (export "run") (result i32)
      (drop (call $ytr (call $new (i32.const 0) (i32.const 0))))
      (i32.const 7)))
  (core instance $i (instantiate $m (with "" (instance
    (export "new" (func $new)) (export "ytr" (func $ytr))
    (export "suspend" (func $suspend)) (export "t" (table $t))))))
  (func (export "run") (result u32) (canon lift (core func $i "run"))))
