;; Two exported resource types, `a` and `b`, each with a constructor, a `get`
;; method and a destructor, for the host handle table's type checks. A
;; representation is the value the constructor was given (plus 1000 for `b`), so
;; `get` answers it back. Each destructor counts its calls in a global that
;; `dtor-count` reads, and `churn-a` mints an `a` and drops it from inside the
;; guest, then answers that count: the guest's own drop runs the destructor.
;; The core module takes the toolchain's shape (`[export]<iface>` intrinsics and
;; `<iface>#...` exports), so it runs on the single-core path like `counter`.
(component
  (type $a (resource (rep i32)))
  (type $b (resource (rep i32)))
  (core func $new-a (canon resource.new $a))
  (core func $drop-a (canon resource.drop $a))
  (core func $new-b (canon resource.new $b))
  (core func $drop-b (canon resource.drop $b))
  (core module $m
    (import "[export]example:two/things" "[resource-new]a"
      (func $new-a (param i32) (result i32)))
    (import "[export]example:two/things" "[resource-drop]a"
      (func $drop-a (param i32)))
    (import "[export]example:two/things" "[resource-new]b"
      (func $new-b (param i32) (result i32)))
    (import "[export]example:two/things" "[resource-drop]b"
      (func $drop-b (param i32)))
    (global $dtors (mut i32) (i32.const 0))
    (func (export "example:two/things#[constructor]a")
      (param i32) (result i32)
      local.get 0 call $new-a)
    (func (export "example:two/things#[constructor]b")
      (param i32) (result i32)
      local.get 0 i32.const 1000 i32.add call $new-b)
    (func (export "example:two/things#[method]a.get")
      (param i32) (result i32)
      local.get 0)
    (func (export "example:two/things#[method]b.get")
      (param i32) (result i32)
      local.get 0)
    (func $dtor (param i32)
      global.get $dtors i32.const 1 i32.add global.set $dtors)
    (export "example:two/things#[dtor]a" (func $dtor))
    (export "example:two/things#[dtor]b" (func $dtor))
    (func (export "example:two/things#dtor-count") (result i32)
      global.get $dtors)
    (func (export "example:two/things#churn-a") (result i32)
      i32.const 7 call $new-a call $drop-a
      global.get $dtors))
  (core instance $things
    (export "[resource-new]a" (func $new-a))
    (export "[resource-drop]a" (func $drop-a))
    (export "[resource-new]b" (func $new-b))
    (export "[resource-drop]b" (func $drop-b)))
  (core instance $main
    (instantiate $m (with "[export]example:two/things" (instance $things))))
  (func $ctor-a (param "init" u32) (result (own $a))
    (canon lift (core func $main "example:two/things#[constructor]a")))
  (func $ctor-b (param "init" u32) (result (own $b))
    (canon lift (core func $main "example:two/things#[constructor]b")))
  (func $get-a (param "self" (borrow $a)) (result u32)
    (canon lift (core func $main "example:two/things#[method]a.get")))
  (func $get-b (param "self" (borrow $b)) (result u32)
    (canon lift (core func $main "example:two/things#[method]b.get")))
  (func $count (result u32)
    (canon lift (core func $main "example:two/things#dtor-count")))
  (func $churn (result u32)
    (canon lift (core func $main "example:two/things#churn-a")))
  ;; The shim the toolchain emits: it re-exports the lifted functions under an
  ;; interface whose resource types are the exported ones.
  (component $shim
    (import "import-type-a" (type $ta (sub resource)))
    (import "import-type-b" (type $tb (sub resource)))
    (import "import-constructor-a"
      (func $ca (param "init" u32) (result (own $ta))))
    (import "import-constructor-b"
      (func $cb (param "init" u32) (result (own $tb))))
    (import "import-method-a-get"
      (func $ga (param "self" (borrow $ta)) (result u32)))
    (import "import-method-b-get"
      (func $gb (param "self" (borrow $tb)) (result u32)))
    (import "import-func-dtor-count" (func $dc (result u32)))
    (import "import-func-churn-a" (func $ch (result u32)))
    (export $ea "a" (type $ta))
    (export $eb "b" (type $tb))
    (export "[constructor]a" (func $ca)
      (func (param "init" u32) (result (own $ea))))
    (export "[constructor]b" (func $cb)
      (func (param "init" u32) (result (own $eb))))
    (export "[method]a.get" (func $ga)
      (func (param "self" (borrow $ea)) (result u32)))
    (export "[method]b.get" (func $gb)
      (func (param "self" (borrow $eb)) (result u32)))
    (export "dtor-count" (func $dc))
    (export "churn-a" (func $ch)))
  (instance $things-inst
    (instantiate $shim
      (with "import-type-a" (type $a))
      (with "import-type-b" (type $b))
      (with "import-constructor-a" (func $ctor-a))
      (with "import-constructor-b" (func $ctor-b))
      (with "import-method-a-get" (func $get-a))
      (with "import-method-b-get" (func $get-b))
      (with "import-func-dtor-count" (func $count))
      (with "import-func-churn-a" (func $churn))))
  (export "example:two/things" (instance $things-inst)))
