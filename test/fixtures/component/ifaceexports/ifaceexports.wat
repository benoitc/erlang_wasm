;; Synchronous interface functions, for `wasm_component_iface_SUITE'. What
;; each checks comes only from its `canon lift': `greet' and `utf16' have the
;; toolchain's names, so they are found either way, and only the post-return
;; and the encoding they declare tell the two apart.
;; - `renamed' lifts core function `impl-a', not `local:t/api#renamed'
;; - `greet' returns "hi there" and names post-return `free-greet', which
;;   counts its calls; `post-returns' answers the count
;; - `utf16' returns "héllo" encoded as UTF-16
;; - `twin' lifts the second core's `local:t/api#twin' (answers 2); the entry
;;   core exports the same name and answers 1
;; `local:t/wrapped' exports `renamed' again through a wrapper component, as
;; wit-component writes an interface.
;; Build: `scripts/build-wat-component-fixtures.sh`.
(component
  (core module $m
    (memory (export "memory") 1)
    (data (i32.const 16) "hi there")
    (data (i32.const 64) "h\00\e9\00l\00l\00o\00")
    (func (export "impl-a") (result i32) (i32.const 1))
    (func (export "local:t/api#greet") (result i32)
      (i32.store (i32.const 32) (i32.const 16))
      (i32.store (i32.const 36) (i32.const 8))
      (i32.const 32))
    (func (export "free-greet") (param i32)
      (i32.store (i32.const 100) (i32.add (i32.load (i32.const 100)) (i32.const 1))))
    (func (export "local:t/api#post-returns") (result i32) (i32.load (i32.const 100)))
    (func (export "local:t/api#utf16") (result i32)
      (i32.store (i32.const 40) (i32.const 64))
      (i32.store (i32.const 44) (i32.const 5))
      (i32.const 40))
    (func (export "local:t/api#twin") (result i32) (i32.const 1))
    ;; Bulk, so this is the largest core and the entry.
    (func $pad (result i32)
      (i32.add (i32.add (i32.add (i32.const 1) (i32.const 2)) (i32.const 3))
               (i32.add (i32.const 4) (i32.const 5)))))
  (core module $m2
    (func (export "local:t/api#twin") (result i32) (i32.const 2)))
  (core instance $a (instantiate $m))
  (core instance $b (instantiate $m2))
  (alias core export $a "memory" (core memory $mem))
  (func $renamed (result u32) (canon lift (core func $a "impl-a")))
  (func $greet (result string)
    (canon lift (core func $a "local:t/api#greet") (memory $mem)
      (post-return (func $a "free-greet"))))
  (func $posts (result u32) (canon lift (core func $a "local:t/api#post-returns")))
  (func $utf16 (result string)
    (canon lift (core func $a "local:t/api#utf16") (memory $mem) string-encoding=utf16))
  (func $twin (result u32) (canon lift (core func $b "local:t/api#twin")))
  (instance $api
    (export "renamed" (func $renamed))
    (export "greet" (func $greet))
    (export "post-returns" (func $posts))
    (export "utf16" (func $utf16))
    (export "twin" (func $twin)))
  (export "local:t/api" (instance $api))
  (component $wrap
    (import "import-func-renamed" (func $f (result u32)))
    (export "renamed" (func $f)))
  (instance $w (instantiate $wrap (with "import-func-renamed" (func $renamed))))
  (export "local:t/wrapped" (instance $w)))
