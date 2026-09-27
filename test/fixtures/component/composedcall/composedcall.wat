;; Cross-component data flow: a provider component exports an interface `host:math/ops`
;; with `add: func(u32, u32) -> u32`; a consumer imports that interface, and its `run`
;; calls add(20, 22). Composed, the consumer's import is wired to the provider's export,
;; so calling the outer `run` returns 42 only if a cross-component call bridges the
;; consumer's core import to the provider's lifted export.
(component
  (component $provider
    (core module $pm
      (func (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add))
    (core instance $pmi (instantiate $pm))
    (func $addf (param "a" u32) (param "b" u32) (result u32)
      (canon lift (core func $pmi "add")))
    (instance $ops (export "add" (func $addf)))
    (export "host:math/ops" (instance $ops)))
  (component $consumer
    (import "host:math/ops" (instance $ops
      (export "add" (func (param "a" u32) (param "b" u32) (result u32)))))
    (alias export $ops "add" (func $add))
    (core func $add_core (canon lower (func $add)))
    (core module $cm
      (import "host:math/ops" "add" (func (param i32 i32) (result i32)))
      (func (export "run") (result i32)
        i32.const 20 i32.const 22 call 0))
    (core instance $cmi (instantiate $cm
      (with "host:math/ops" (instance (export "add" (func $add_core))))))
    (func (export "run") (result u32)
      (canon lift (core func $cmi "run"))))
  (instance $p (instantiate $provider))
  (instance $c (instantiate $consumer (with "host:math/ops" (instance $p "host:math/ops"))))
  (alias export $c "run" (func $r))
  (export "run" (func $r)))
