;; The async Canonical ABI built-ins, one stackful export per behaviour, for
;; `wasm_component_async_abi_SUITE`. Hand-written so each export calls exactly
;; the built-in under test. Build: `scripts/build-wat-component-fixtures.sh`.
(component
  (type $s8 (stream u8))
  (type $s32 (stream u32))
  (type $f32 (future u32))
  (type $pt (tuple u32 u8))
  (type $fpt (future $pt))
  (import "local:abi/host" (instance $host
    (export "compute" (func async (param "x" u32) (result u32)))))

  ;; Memory, and a bump allocator from 4096 for strings the host lowers.
  (core module $libc
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 4096))
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $next))
      (global.set $next (i32.add (local.get $p) (i32.add (local.get 3) (i32.const 8))))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "memory" (core memory $mem))
  (alias core export $libc "realloc" (core func $realloc))

  (core func $ret (canon task.return (result u32)))
  (core func $ret_s8 (canon task.return (result $s8)))
  (core func $read32 (canon stream.read $s32 (memory $mem)))
  (core func $read8_async (canon stream.read $s8 async (memory $mem)))
  (core func $cancel_read8 (canon stream.cancel-read $s8))
  (core func $new8 (canon stream.new $s8))
  (core func $new32 (canon stream.new $s32))
  (core func $write32_async (canon stream.write $s32 async (memory $mem)))
  (core func $ret_s32 (canon task.return (result $s32)))
  (core func $write8_async (canon stream.write $s8 async (memory $mem)))
  (core func $cancel_write8 (canon stream.cancel-write $s8))
  (core func $fread32 (canon future.read $f32 (memory $mem)))
  (core func $fnew32 (canon future.new $f32))
  (core func $fdropw32 (canon future.drop-writable $f32))
  (core func $freadpt (canon future.read $fpt (memory $mem)))
  (core func $ec_new (canon error-context.new (memory $mem)))
  (core func $ec_msg (canon error-context.debug-message (memory $mem) (realloc $realloc)))
  (core func $ec_drop (canon error-context.drop))
  (core func $task_cancel (canon task.cancel))
  (core func $yield (canon thread.yield))
  (core func $bp_inc (canon backpressure.inc))
  (core func $bp_dec (canon backpressure.dec))
  (core func $ws_new (canon waitable-set.new))
  (core func $ws_wait (canon waitable-set.wait (memory $mem)))
  (core func $st_cancel (canon subtask.cancel))
  (core func $st_drop (canon subtask.drop))
  (core func $compute (canon lower (func $host "compute") async (memory $mem)))

  (core module $m
    (import "" "memory" (memory 1))
    (import "" "ret" (func $ret (param i32)))
    (import "" "ret_s8" (func $ret_s8 (param i32)))
    (import "" "read32" (func $read32 (param i32 i32 i32) (result i32)))
    (import "" "read8_async" (func $read8_async (param i32 i32 i32) (result i32)))
    (import "" "cancel_read8" (func $cancel_read8 (param i32) (result i32)))
    (import "" "new8" (func $new8 (result i64)))
    (import "" "new32" (func $new32 (result i64)))
    (import "" "write32_async" (func $write32_async (param i32 i32 i32) (result i32)))
    (import "" "ret_s32" (func $ret_s32 (param i32)))
    (import "" "write8_async" (func $write8_async (param i32 i32 i32) (result i32)))
    (import "" "cancel_write8" (func $cancel_write8 (param i32) (result i32)))
    (import "" "fread32" (func $fread32 (param i32 i32) (result i32)))
    (import "" "fnew32" (func $fnew32 (result i64)))
    (import "" "fdropw32" (func $fdropw32 (param i32)))
    (import "" "freadpt" (func $freadpt (param i32 i32) (result i32)))
    (import "" "ec_new" (func $ec_new (param i32 i32) (result i32)))
    (import "" "ec_msg" (func $ec_msg (param i32 i32)))
    (import "" "ec_drop" (func $ec_drop (param i32)))
    (import "" "task_cancel" (func $task_cancel))
    (import "" "yield" (func $yield (result i32)))
    (import "" "bp_inc" (func $bp_inc))
    (import "" "bp_dec" (func $bp_dec))
    (import "" "ws_new" (func $ws_new (result i32)))
    (import "" "ws_wait" (func $ws_wait (param i32 i32) (result i32)))
    (import "" "st_cancel" (func $st_cancel (param i32) (result i32)))
    (import "" "st_drop" (func $st_drop (param i32)))
    (import "" "compute" (func $compute (param i32 i32) (result i32)))
    (data (i32.const 256) "boom")
    (data (i32.const 512) "\01\00\00\00\00\01\00\00\ff\ff\ff\ff")

    ;; ints() -> stream<u32>: a stream the guest makes, three u32s written to it.
    (func (export "[async-lift]ints")
      (local $p i64)
      (local.set $p (call $new32))
      (call $ret_s32 (i32.wrap_i64 (local.get $p)))
      (drop (call $write32_async
        (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32)))
        (i32.const 512) (i32.const 3))))

    ;; sum32(s: stream<u32>) -> u32, with blocking reads of up to 4 elements.
    (func (export "[async-lift]sum32") (param $h i32)
      (local $r i32) (local $n i32) (local $i i32) (local $sum i32)
      (block $done
        (loop $more
          (local.set $r (call $read32 (local.get $h) (i32.const 64) (i32.const 4)))
          (local.set $n (i32.shr_u (local.get $r) (i32.const 4)))
          (local.set $i (i32.const 0))
          (block $e (loop $add
            (br_if $e (i32.ge_u (local.get $i) (local.get $n)))
            (local.set $sum (i32.add (local.get $sum)
              (i32.load (i32.add (i32.const 64) (i32.shl (local.get $i) (i32.const 2))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $add)))
          (br_if $done (i32.eq (i32.and (local.get $r) (i32.const 15)) (i32.const 1)))
          (br $more)))
      (call $ret (local.get $sum)))

    ;; cancel-read(s: stream<u8>) -> u32: an async read that blocks, then its
    ;; cancellation's packed result.
    (func (export "[async-lift]cancel-read") (param $h i32)
      (drop (call $read8_async (local.get $h) (i32.const 64) (i32.const 8)))
      (call $ret (call $cancel_read8 (local.get $h))))

    ;; cancel-idle() -> u32: cancelling a read that is not pending traps.
    (func (export "[async-lift]cancel-idle")
      (call $ret (call $cancel_read8 (i32.wrap_i64 (call $new8)))))

    ;; read-twice(f: future<u32>) -> u32: the second read of a future traps.
    (func (export "[async-lift]read-twice") (param $h i32)
      (drop (call $fread32 (local.get $h) (i32.const 64)))
      (drop (call $fread32 (local.get $h) (i32.const 64)))
      (call $ret (i32.load (i32.const 64))))

    ;; drop-unwritten() -> u32: dropping a future's writer before it wrote traps.
    (func (export "[async-lift]drop-unwritten")
      (call $fdropw32 (i32.wrap_i64 (i64.shr_u (call $fnew32) (i64.const 32))))
      (call $ret (i32.const 0)))

    ;; point(f: future<tuple<u32, u8>>) -> u32: the sum of the pair read.
    (func (export "[async-lift]point") (param $h i32)
      (drop (call $freadpt (local.get $h) (i32.const 64)))
      (call $ret (i32.add (i32.load (i32.const 64)) (i32.load8_u (i32.const 68)))))

    ;; bounded() -> u32: writes of 5000 bytes to a stream nobody reads. Packs the
    ;; first write's progress << 8, BLOCKED for the second << 4, and the result
    ;; of cancelling it.
    (func (export "[async-lift]bounded")
      (local $w i32) (local $r1 i32) (local $r2 i32)
      (local.set $w (i32.wrap_i64 (i64.shr_u (call $new8) (i64.const 32))))
      (local.set $r1 (call $write8_async (local.get $w) (i32.const 8192) (i32.const 5000)))
      (local.set $r2 (call $write8_async (local.get $w) (i32.const 8192) (i32.const 5000)))
      (call $ret (i32.or (i32.or
        (i32.shl (i32.shr_u (local.get $r1) (i32.const 4)) (i32.const 8))
        (i32.shl (i32.eq (local.get $r2) (i32.const -1)) (i32.const 4)))
        (i32.and (call $cancel_write8 (local.get $w)) (i32.const 15)))))

    ;; big() -> stream<u8>: 5000 bytes written to a stream the host reads.
    (func (export "[async-lift]big")
      (local $p i64) (local $r i32)
      (local.set $p (call $new8))
      (call $ret_s8 (i32.wrap_i64 (local.get $p)))
      (local.set $r (call $write8_async
        (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32)))
        (i32.const 8192) (i32.const 5000)))
      (if (i32.ne (local.get $r) (i32.const 80000)) (then unreachable)))

    ;; error-message() -> u32: an error context's message read back, packed as
    ;; length << 8 | first byte.
    (func (export "[async-lift]error-message")
      (local $e i32)
      (local.set $e (call $ec_new (i32.const 256) (i32.const 4)))
      (call $ec_msg (local.get $e) (i32.const 128))
      (call $ec_drop (local.get $e))
      (call $ret (i32.or (i32.shl (i32.load (i32.const 132)) (i32.const 8))
                         (i32.load8_u (i32.load (i32.const 128))))))

    ;; error-drop-twice() -> u32: the second drop traps.
    (func (export "[async-lift]error-drop-twice")
      (local $e i32)
      (local.set $e (call $ec_new (i32.const 256) (i32.const 4)))
      (call $ec_drop (local.get $e))
      (call $ec_drop (local.get $e))
      (call $ret (i32.const 0)))

    (func (export "[async-lift]task-cancel")
      (call $task_cancel)
      (call $ret (i32.const 0)))

    ;; yield() -> u32: 0, not cancelled.
    (func (export "[async-lift]yield")
      (call $ret (call $yield)))

    (func (export "[async-lift]bp-raise")
      (call $bp_inc)
      (call $ret (i32.const 1)))

    (func (export "[async-lift]bp-balance")
      (call $bp_inc)
      (call $bp_dec)
      (call $ret (i32.const 1)))

    (func (export "[async-lift]bp-under")
      (call $bp_dec)
      (call $ret (i32.const 1)))

    ;; deadlock() -> u32: a wait on a set nothing can complete.
    (func (export "[async-lift]deadlock")
      (call $ret (call $ws_wait (call $ws_new) (i32.const 64))))

    ;; cancel-subtask(x) -> u32: start `compute', cancel it, drop it, return the
    ;; state the cancellation reported.
    (func (export "[async-lift]cancel-subtask") (param $x i32)
      (local $st i32) (local $c i32)
      (local.set $st (i32.shr_u (call $compute (local.get $x) (i32.const 64)) (i32.const 4)))
      (local.set $c (call $st_cancel (local.get $st)))
      (call $st_drop (local.get $st))
      (call $ret (local.get $c)))

    ;; drop-running(x) -> u32: dropping a subtask that has not resolved traps.
    (func (export "[async-lift]drop-running") (param $x i32)
      (call $st_drop (i32.shr_u (call $compute (local.get $x) (i32.const 64)) (i32.const 4)))
      (call $ret (i32.const 0))))

  (core instance $i (instantiate $m (with "" (instance
    (export "memory" (memory $mem))
    (export "ret" (func $ret)) (export "ret_s8" (func $ret_s8))
    (export "read32" (func $read32)) (export "read8_async" (func $read8_async))
    (export "cancel_read8" (func $cancel_read8)) (export "new8" (func $new8))
    (export "new32" (func $new32)) (export "write32_async" (func $write32_async))
    (export "ret_s32" (func $ret_s32))
    (export "write8_async" (func $write8_async))
    (export "cancel_write8" (func $cancel_write8))
    (export "fread32" (func $fread32)) (export "fnew32" (func $fnew32))
    (export "fdropw32" (func $fdropw32)) (export "freadpt" (func $freadpt))
    (export "ec_new" (func $ec_new)) (export "ec_msg" (func $ec_msg))
    (export "ec_drop" (func $ec_drop)) (export "task_cancel" (func $task_cancel))
    (export "yield" (func $yield)) (export "bp_inc" (func $bp_inc))
    (export "bp_dec" (func $bp_dec)) (export "ws_new" (func $ws_new))
    (export "ws_wait" (func $ws_wait)) (export "st_cancel" (func $st_cancel))
    (export "st_drop" (func $st_drop)) (export "compute" (func $compute))))))

  (func (export "sum32") async (param "s" $s32) (result u32)
    (canon lift (core func $i "[async-lift]sum32") async))
  (func (export "cancel-read") async (param "s" $s8) (result u32)
    (canon lift (core func $i "[async-lift]cancel-read") async))
  (func (export "cancel-idle") async (result u32)
    (canon lift (core func $i "[async-lift]cancel-idle") async))
  (func (export "read-twice") async (param "f" $f32) (result u32)
    (canon lift (core func $i "[async-lift]read-twice") async))
  (func (export "drop-unwritten") async (result u32)
    (canon lift (core func $i "[async-lift]drop-unwritten") async))
  (func (export "point") async (param "f" $fpt) (result u32)
    (canon lift (core func $i "[async-lift]point") async))
  (func (export "bounded") async (result u32)
    (canon lift (core func $i "[async-lift]bounded") async))
  (func (export "ints") async (result $s32)
    (canon lift (core func $i "[async-lift]ints") async))
  (func (export "big") async (result $s8)
    (canon lift (core func $i "[async-lift]big") async))
  (func (export "error-message") async (result u32)
    (canon lift (core func $i "[async-lift]error-message") async))
  (func (export "error-drop-twice") async (result u32)
    (canon lift (core func $i "[async-lift]error-drop-twice") async))
  (func (export "task-cancel") async (result u32)
    (canon lift (core func $i "[async-lift]task-cancel") async))
  (func (export "yield") async (result u32)
    (canon lift (core func $i "[async-lift]yield") async))
  (func (export "bp-raise") async (result u32)
    (canon lift (core func $i "[async-lift]bp-raise") async))
  (func (export "bp-balance") async (result u32)
    (canon lift (core func $i "[async-lift]bp-balance") async))
  (func (export "bp-under") async (result u32)
    (canon lift (core func $i "[async-lift]bp-under") async))
  (func (export "deadlock") async (result u32)
    (canon lift (core func $i "[async-lift]deadlock") async))
  (func (export "cancel-subtask") async (param "x" u32) (result u32)
    (canon lift (core func $i "[async-lift]cancel-subtask") async))
  (func (export "drop-running") async (param "x" u32) (result u32)
    (canon lift (core func $i "[async-lift]drop-running") async))
)
