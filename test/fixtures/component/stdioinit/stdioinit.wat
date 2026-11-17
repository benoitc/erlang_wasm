;; A component that takes its stdout and stderr during `init' and keeps the
;; two handles, for `wasm_component_snapshot_SUITE'. `out' and `err' answer
;; them, so the host can check what each stands for after a restore. Its core
;; imports both, and a sibling core's `seven', under one namespace named "",
;; which is no interface's name: a capture must still find which of the three
;; come from outside the component.
(component
  (import "wasi:io/streams@0.2.0" (instance $streams
    (export "output-stream" (type (sub resource)))))
  (alias export $streams "output-stream" (type $os))
  (import "wasi:cli/stdout@0.2.0" (instance $stdout
    (alias outer 1 $os (type $os'))
    (export "get-stdout" (func (result (own $os'))))))
  (import "wasi:cli/stderr@0.2.0" (instance $stderr
    (alias outer 1 $os (type $os'))
    (export "get-stderr" (func (result (own $os'))))))
  (core func $gso (canon lower (func $stdout "get-stdout")))
  (core func $gse (canon lower (func $stderr "get-stderr")))
  (core module $helper (func (export "seven") (result i32) (i32.const 7)))
  (core instance $h (instantiate $helper))
  (core module $m
    (import "" "seven" (func $seven (result i32)))
    (import "" "get-stdout" (func $gso (result i32)))
    (import "" "get-stderr" (func $gse (result i32)))
    (global $out (mut i32) (i32.const 0))
    (global $err (mut i32) (i32.const 0))
    (func (export "init")
      (global.set $out (call $gso))
      (global.set $err (call $gse)))
    (func (export "out") (result i32) (global.get $out))
    (func (export "err") (result i32) (global.get $err))
    (func (export "seven") (result i32) (call $seven)))
  (core instance $i (instantiate $m (with "" (instance
    (export "seven" (func $h "seven"))
    (export "get-stdout" (func $gso)) (export "get-stderr" (func $gse))))))
  (func (export "init") (canon lift (core func $i "init")))
  (func (export "out") (result u32) (canon lift (core func $i "out")))
  (func (export "err") (result u32) (canon lift (core func $i "err")))
  (func (export "seven") (result u32) (canon lift (core func $i "seven"))))
