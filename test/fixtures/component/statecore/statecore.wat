(component
  ;; One core with a mutable global. `bump` increments it and returns the new
  ;; value, so the result reveals whether the instance is fresh: a cold instance
  ;; per call returns 1 every time, a reused one would climb. Lifted as a
  ;; component function so it runs through the whole component path.
  (core module $m
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (core instance $i (instantiate $m))
  (func (export "bump") (result u32)
    (canon lift (core func $i "bump"))))
