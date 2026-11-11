;; A single-core component that calls an async host import, for
;; `wasm_component_version_SUITE`. `ping' takes one u32 and returns nothing, so
;; its async lowering needs no memory and the component has one core module and
;; no built-ins: it stays off the linker. `run' calls it and returns the
;; subtask status it got. Build: `scripts/build-wat-component-fixtures.sh`.
(component
  (import "local:ping/host" (instance $h
    (export "ping" (func async (param "x" u32)))))
  (core func $ping (canon lower (func $h "ping") async))
  (core module $m
    (import "local:ping/host" "ping" (func $ping (param i32) (result i32)))
    (func (export "run") (param i32) (result i32) (call $ping (local.get 0))))
  (core instance $i (instantiate $m
    (with "local:ping/host" (instance (export "ping" (func $ping))))))
  (func (export "run") (param "x" u32) (result u32) (canon lift (core func $i "run"))))
