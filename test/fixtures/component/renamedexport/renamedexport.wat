(component
  ;; The core exports "bump"; the component lifts it and exports it under the
  ;; different name "step". Calling the component export "step" must reach the core
  ;; function "bump" through the export wiring, not by a matching core export name.
  (core module $m
    (global $g (mut i32) (i32.const 0))
    (func (export "bump") (result i32)
      (global.set $g (i32.add (global.get $g) (i32.const 1)))
      (global.get $g)))
  (core instance $i (instantiate $m))
  (func $step (result u32) (canon lift (core func $i "bump")))
  (export "step" (func $step)))
