;; Versioned host keys, for `wasm_component_version_SUITE`. The component
;; imports `wasi:random/random' at both 0.2.12 and 0.3.2, as a WASI 0.3 program
;; built through the wasip1 adapter does, and exports one function per import,
;; so a case can tell which host function each import reached. Build:
;; `scripts/build-wat-component-fixtures.sh`.
(component
  (import "wasi:random/random@0.2.12" (instance $r2
    (export "get-random-u64" (func (result u64)))))
  (import "wasi:random/random@0.3.2" (instance $r3
    (export "get-random-u64" (func (result u64)))))
  (core func $u64_2 (canon lower (func $r2 "get-random-u64")))
  (core func $u64_3 (canon lower (func $r3 "get-random-u64")))
  (core module $m
    (import "wasi:random/random@0.2.12" "get-random-u64" (func $u2 (result i64)))
    (import "wasi:random/random@0.3.2" "get-random-u64" (func $u3 (result i64)))
    (func (export "roll2") (result i64) (call $u2))
    (func (export "roll3") (result i64) (call $u3)))
  (core instance $i (instantiate $m
    (with "wasi:random/random@0.2.12" (instance (export "get-random-u64" (func $u64_2))))
    (with "wasi:random/random@0.3.2" (instance (export "get-random-u64" (func $u64_3))))))
  (func (export "roll2") (result u64) (canon lift (core func $i "roll2")))
  (func (export "roll3") (result u64) (canon lift (core func $i "roll3"))))
