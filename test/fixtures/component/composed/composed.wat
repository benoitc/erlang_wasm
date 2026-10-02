;; A composed component: the outer component DEFINES an inner component (a nested
;; component section), INSTANTIATES it (a component-instance section), ALIASES the
;; instance's `run` export, and re-exports it. Calling the outer `run` must reach the
;; inner component's core function and return 42. This is the minimal shape a
;; `wac`/`wasm-tools compose` output takes: one component's export wired through a
;; component instance, which the linker must instantiate and alias across.
(component
  (component $inner
    (core module $m
      (func (export "run") (result i32)
        i32.const 42))
    (core instance $mi (instantiate $m))
    (func (export "run") (result u32)
      (canon lift (core func $mi "run"))))
  (instance $i (instantiate $inner))
  (alias export $i "run" (func $r))
  (export "run" (func $r)))
