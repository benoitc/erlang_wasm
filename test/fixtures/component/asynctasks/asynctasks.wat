;; Tasks that outlive their call, for `wasm_component_async_tasks_SUITE'.
;; `body' (a callback lift) creates a stream<u8>, hands back its reader through
;; `task.return' at once, and then writes 3000 bytes to it, waiting for room
;; whenever the reader has not taken them. Task k writes the byte k, and keeps
;; its state in its own block, found through context slot 0, so two tasks
;; interleaving each write their own bytes. The stackful exports read what a
;; host import hands them: a stream (`sum-feed'), a future (`take-future'), and
;; whether a host-end call inside an import is refused (`reenter'). `drop-feed'
;; drops the stream `feed' returns unread.
;; Build: `scripts/build-wat-component-fixtures.sh`.
(component
  (type $s8 (stream u8))
  (type $f32 (future u32))
  (import "local:tasks/host" (instance $host
    (export "s8" (type (eq $s8)))
    (export "f32" (type (eq $f32)))
    (export "feed" (func (result $s8)))
    (export "fut" (func (result $f32)))
    (export "reenter" (func (result u32)))
    (export "take" (func (param "s" $s8) (result u32)))))
  (alias export $host "feed" (func $feed))
  (alias export $host "fut" (func $fut))
  (alias export $host "reenter" (func $reenter))
  (alias export $host "take" (func $take))

  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "memory" (core memory $mem))

  (core func $new8 (canon stream.new $s8))
  (core func $write8 (canon stream.write $s8 async (memory $mem)))
  (core func $dropw8 (canon stream.drop-writable $s8))
  (core func $read8 (canon stream.read $s8 (memory $mem)))
  (core func $dropr8 (canon stream.drop-readable $s8))
  (core func $fread (canon future.read $f32 (memory $mem)))
  (core func $ret_s8 (canon task.return (result $s8)))
  (core func $ret (canon task.return (result u32)))
  (core func $ws_new (canon waitable-set.new))
  (core func $join (canon waitable.join))
  (core func $ctx_get (canon context.get i32 0))
  (core func $ctx_set (canon context.set i32 0))
  (core func $feed_l (canon lower (func $feed)))
  (core func $fut_l (canon lower (func $fut)))
  (core func $reenter_l (canon lower (func $reenter)))
  (core func $take_l (canon lower (func $take)))

  (core module $m
    (import "" "memory" (memory 1))
    (import "" "new8" (func $new8 (result i64)))
    (import "" "write8" (func $write8 (param i32 i32 i32) (result i32)))
    (import "" "dropw8" (func $dropw8 (param i32)))
    (import "" "read8" (func $read8 (param i32 i32 i32) (result i32)))
    (import "" "dropr8" (func $dropr8 (param i32)))
    (import "" "fread" (func $fread (param i32 i32) (result i32)))
    (import "" "ret_s8" (func $ret_s8 (param i32)))
    (import "" "ret" (func $ret (param i32)))
    (import "" "ws_new" (func $ws_new (result i32)))
    (import "" "join" (func $join (param i32 i32)))
    (import "" "ctx_get" (func $ctx_get (result i32)))
    (import "" "ctx_set" (func $ctx_set (param i32)))
    (import "" "feed" (func $feed (result i32)))
    (import "" "fut" (func $fut (result i32)))
    (import "" "reenter" (func $reenter (result i32)))
    (import "" "take" (func $take (param i32) (result i32)))
    (global $tasks (mut i32) (i32.const 0))

    ;; State block P: writer +0, bytes left +4, waitable-set +8, data +12.
    (func $write_more (param $p i32) (result i32)
      (local $res i32) (local $left i32)
      (block $done
        (loop $more
          (local.set $left (i32.load offset=4 (local.get $p)))
          (local.set $res (call $write8 (i32.load (local.get $p))
            (i32.add (i32.load offset=12 (local.get $p))
                     (i32.sub (i32.const 3000) (local.get $left)))
            (local.get $left)))
          (if (i32.eq (local.get $res) (i32.const -1))
            (then (return (i32.or (i32.const 2)
                    (i32.shl (i32.load offset=8 (local.get $p)) (i32.const 4))))))
          (br_if $done (i32.eq (i32.and (local.get $res) (i32.const 15)) (i32.const 1)))
          (i32.store offset=4 (local.get $p)
            (i32.sub (local.get $left) (i32.shr_u (local.get $res) (i32.const 4))))
          (br_if $done (i32.eqz (i32.load offset=4 (local.get $p))))
          (br $more)))
      (call $dropw8 (i32.load (local.get $p)))
      (i32.const 0))

    (func (export "[async-lift]body") (result i32)
      (local $k i32) (local $p i32) (local $pair i64) (local $set i32)
      (global.set $tasks (i32.add (global.get $tasks) (i32.const 1)))
      (local.set $k (global.get $tasks))
      (local.set $p (i32.add (i32.const 256) (i32.shl (local.get $k) (i32.const 4))))
      (call $ctx_set (local.get $p))
      (i32.store offset=12 (local.get $p)
        (i32.add (i32.const 8192) (i32.shl (local.get $k) (i32.const 12))))
      (memory.fill (i32.load offset=12 (local.get $p)) (local.get $k) (i32.const 3000))
      (local.set $pair (call $new8))
      (i32.store (local.get $p) (i32.wrap_i64 (i64.shr_u (local.get $pair) (i64.const 32))))
      (i32.store offset=4 (local.get $p) (i32.const 3000))
      (call $ret_s8 (i32.wrap_i64 (local.get $pair)))
      (local.set $set (call $ws_new))
      (call $join (i32.load (local.get $p)) (local.get $set))
      (i32.store offset=8 (local.get $p) (local.get $set))
      (call $write_more (local.get $p)))

    (func (export "[callback][async-lift]body") (param $ev i32) (param $h i32)
                                                (param $payload i32) (result i32)
      (local $p i32)
      (local.set $p (call $ctx_get))
      (if (i32.eq (local.get $ev) (i32.const 3))
        (then
          (i32.store offset=4 (local.get $p)
            (i32.sub (i32.load offset=4 (local.get $p))
                     (i32.shr_u (local.get $payload) (i32.const 4))))
          (if (i32.eqz (i32.load offset=4 (local.get $p)))
            (then (call $dropw8 (i32.load (local.get $p))) (return (i32.const 0))))))
      (call $write_more (local.get $p)))

    ;; sum-feed() -> u32: the sum of the bytes of the stream `feed' returns.
    (func (export "[async-lift]sum-feed")
      (local $h i32) (local $r i32) (local $n i32) (local $i i32) (local $sum i32)
      (local.set $h (call $feed))
      (block $done
        (loop $more
          (local.set $r (call $read8 (local.get $h) (i32.const 64) (i32.const 16)))
          (local.set $n (i32.shr_u (local.get $r) (i32.const 4)))
          (local.set $i (i32.const 0))
          (block $e (loop $add
            (br_if $e (i32.ge_u (local.get $i) (local.get $n)))
            (local.set $sum (i32.add (local.get $sum)
              (i32.load8_u (i32.add (i32.const 64) (local.get $i)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $add)))
          (br_if $done (i32.eq (i32.and (local.get $r) (i32.const 15)) (i32.const 1)))
          (br $more)))
      (call $ret (local.get $sum)))

    ;; drop-feed() -> u32: drops the stream `feed' returns, unread, then
    ;; answers 7.
    (func (export "[async-lift]drop-feed")
      (call $dropr8 (call $feed))
      (call $ret (i32.const 7)))

    ;; take-future() -> u32: the value of the future `fut' returns.
    (func (export "[async-lift]take-future")
      (drop (call $fread (call $fut) (i32.const 64)))
      (call $ret (i32.load (i32.const 64))))

    (func (export "[async-lift]reenter")
      (call $ret (call $reenter)))

    ;; ended() -> u32: writes "abc" to a new stream, ends it, then hands the
    ;; reader to `take', which answers what it got.
    (func (export "[async-lift]ended")
      (local $pair i64)
      (local.set $pair (call $new8))
      (i32.store (i32.const 128) (i32.const 0x00636261))
      (drop (call $write8 (i32.wrap_i64 (i64.shr_u (local.get $pair) (i64.const 32)))
                          (i32.const 128) (i32.const 3)))
      (call $dropw8 (i32.wrap_i64 (i64.shr_u (local.get $pair) (i64.const 32))))
      (call $ret (call $take (i32.wrap_i64 (local.get $pair))))))

  (core instance $i (instantiate $m (with "" (instance
    (export "memory" (memory $mem))
    (export "new8" (func $new8)) (export "write8" (func $write8))
    (export "dropw8" (func $dropw8)) (export "read8" (func $read8))
    (export "dropr8" (func $dropr8))
    (export "fread" (func $fread)) (export "ret_s8" (func $ret_s8))
    (export "ret" (func $ret)) (export "ws_new" (func $ws_new))
    (export "join" (func $join)) (export "ctx_get" (func $ctx_get))
    (export "ctx_set" (func $ctx_set)) (export "feed" (func $feed_l))
    (export "fut" (func $fut_l)) (export "reenter" (func $reenter_l))
    (export "take" (func $take_l))))))

  (func (export "body") async (result $s8)
    (canon lift (core func $i "[async-lift]body") async
      (callback (func $i "[callback][async-lift]body"))))
  (func (export "sum-feed") async (result u32)
    (canon lift (core func $i "[async-lift]sum-feed") async))
  (func (export "drop-feed") async (result u32)
    (canon lift (core func $i "[async-lift]drop-feed") async))
  (func (export "take-future") async (result u32)
    (canon lift (core func $i "[async-lift]take-future") async))
  (func (export "reenter") async (result u32)
    (canon lift (core func $i "[async-lift]reenter") async))
  (func (export "ended") async (result u32)
    (canon lift (core func $i "[async-lift]ended") async)))
