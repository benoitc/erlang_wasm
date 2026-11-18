;; For `wasm_component_link_SUITE': a lift whose type sits in a second type
;; section and does not match its core function. `$ok' is in the first type
;; section and matches; the core module between the two sections makes the
;; encoder start a new one, so `$bad' is type 1 of the component's type space
;; but the first entry of the second section. `bad' declares a u32 result for a
;; core function that returns an f64. Deliberately invalid, so the build script
;; does not validate it.
(component
  (type $ok (func (result u32)))
  (core module $m
    (func (export "good") (result i32) (i32.const 1))
    (func (export "bad") (result f64) (f64.const 1)))
  (core instance $i (instantiate $m))
  (type $bad (func (result u32)))
  (func (export "good") (type $ok) (canon lift (core func $i "good")))
  (func (export "bad") (type $bad) (canon lift (core func $i "bad"))))
