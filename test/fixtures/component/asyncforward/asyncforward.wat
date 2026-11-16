;; `stream.forward' and `future.forward', for `wasm_component_forward_SUITE'.
;; No tool writes them yet, so this text names `stream.drop-readable' and
;; `future.drop-readable', which have the same operand, each alone in its
;; canon section; `scripts/build-wat-component-fixtures.sh' then rewrites the
;; two opcodes (0x13 and 0x1a) to the forwards' (0x2e and 0x2f). The core
;; module imports them with the forwards' type, `(param i32 i32)'.
(component
  (type $s32 (stream u32))
  (type $f32 (future u32))
  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "memory" (core memory $mem))

  (core func $sfwd (canon stream.drop-readable $s32))
  (core type $sep1 (func))
  (core func $ffwd (canon future.drop-readable $f32))
  (core type $sep2 (func))

  (core func $new32 (canon stream.new $s32))
  (core func $newf (canon future.new $f32))
  (core func $ret_s32 (canon task.return (result $s32)))
  (core func $ret_f32 (canon task.return (result $f32)))
  (core func $ret (canon task.return (result u32)))
  (core func $read32_async (canon stream.read $s32 async (memory $mem)))
  (core func $dropr32 (canon stream.drop-readable $s32))
  (core func $ws_new (canon waitable-set.new))
  (core func $join (canon waitable.join))

  (core module $m
    (import "" "mem" (memory 1))
    (import "" "sfwd" (func $sfwd (param i32 i32)))
    (import "" "ffwd" (func $ffwd (param i32 i32)))
    (import "" "new32" (func $new32 (result i64)))
    (import "" "newf" (func $newf (result i64)))
    (import "" "ret_s32" (func $ret_s32 (param i32)))
    (import "" "ret_f32" (func $ret_f32 (param i32)))
    (import "" "ret" (func $ret (param i32)))
    (import "" "read32_async" (func $read32_async (param i32 i32 i32) (result i32)))
    (import "" "dropr32" (func $dropr32 (param i32)))
    (import "" "ws_new" (func $ws_new (result i32)))
    (import "" "join" (func $join (param i32 i32)))

    ;; pipe(s) -> stream<u32>: forwards `s' into a new stream it returns.
    (func (export "[async-lift]pipe") (param $s i32)
      (local $p i64)
      (local.set $p (call $new32))
      (call $sfwd (local.get $s) (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32))))
      (call $ret_s32 (i32.wrap_i64 (local.get $p))))

    ;; pipe-future(f) -> future<u32>: forwards `f' into a new future.
    (func (export "[async-lift]pipe-future") (param $f i32)
      (local $p i64)
      (local.set $p (call $newf))
      (call $ffwd (local.get $f) (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32))))
      (call $ret_f32 (i32.wrap_i64 (local.get $p))))

    ;; loop() -> u32: forwards a stream into its own writable end, which drops
    ;; both, then drops the readable end again: that traps.
    (func (export "[async-lift]loop")
      (local $p i64)
      (local.set $p (call $new32))
      (call $sfwd (i32.wrap_i64 (local.get $p))
                  (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32))))
      (call $dropr32 (i32.wrap_i64 (local.get $p)))
      (call $ret (i32.const 0)))

    ;; busy() -> u32: forwards a readable end with a read in progress: traps.
    (func (export "[async-lift]busy")
      (local $a i64) (local $b i64)
      (local.set $a (call $new32))
      (local.set $b (call $new32))
      (drop (call $read32_async (i32.wrap_i64 (local.get $a)) (i32.const 64) (i32.const 4)))
      (call $sfwd (i32.wrap_i64 (local.get $a))
                  (i32.wrap_i64 (i64.shr_u (local.get $b) (i64.const 32))))
      (call $ret (i32.const 0)))

    ;; in-set() -> u32: forwards a readable end in a waitable set: traps.
    (func (export "[async-lift]in-set")
      (local $a i64) (local $b i64)
      (local.set $a (call $new32))
      (local.set $b (call $new32))
      (call $join (i32.wrap_i64 (local.get $a)) (call $ws_new))
      (call $sfwd (i32.wrap_i64 (local.get $a))
                  (i32.wrap_i64 (i64.shr_u (local.get $b) (i64.const 32))))
      (call $ret (i32.const 0))))

  (core instance $i (instantiate $m (with "" (instance
    (export "mem" (memory $mem))
    (export "sfwd" (func $sfwd)) (export "ffwd" (func $ffwd))
    (export "new32" (func $new32)) (export "newf" (func $newf))
    (export "ret_s32" (func $ret_s32)) (export "ret_f32" (func $ret_f32))
    (export "ret" (func $ret)) (export "read32_async" (func $read32_async))
    (export "dropr32" (func $dropr32)) (export "ws_new" (func $ws_new))
    (export "join" (func $join))))))

  (func (export "pipe") async (param "s" $s32) (result $s32)
    (canon lift (core func $i "[async-lift]pipe") async))
  (func (export "pipe-future") async (param "f" $f32) (result $f32)
    (canon lift (core func $i "[async-lift]pipe-future") async))
  (func (export "loop") async (result u32)
    (canon lift (core func $i "[async-lift]loop") async))
  (func (export "busy") async (result u32)
    (canon lift (core func $i "[async-lift]busy") async))
  (func (export "in-set") async (result u32)
    (canon lift (core func $i "[async-lift]in-set") async)))
