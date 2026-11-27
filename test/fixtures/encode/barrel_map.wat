;; A map function of the kind Barrel installs for a view: it imports the host
;; functions it calls, owns one memory, and exports what the host calls. The
;; host writes a document at the address `alloc' returns and calls `map',
;; which emits one key and value per row.
(module
  (import "barrel" "emit" (func $emit (param i32 i32 i32 i32)))
  (import "barrel" "log" (func $log (param i32 i32)))
  (memory (export "memory") 1)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "alloc") (param $n i32) (result i32)
    (local $p i32)
    global.get $heap
    local.tee $p
    local.get $n
    i32.add
    global.set $heap
    local.get $p)
  (func (export "map") (param $doc i32) (param $len i32) (result i32)
    (if (i32.eqz (local.get $len))
      (then
        (call $log (i32.const 0) (i32.const 5))
        (return (i32.const 1))))
    (call $emit (i32.const 8) (i32.const 6) (local.get $doc) (local.get $len))
    i32.const 0)
  (data (i32.const 0) "empty\00\00\00by_doc"))
