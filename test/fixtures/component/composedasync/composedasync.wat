;; A call from one component into another's async export, with a stream and a
;; future crossing, for `wasm_component_compose_SUITE'. The provider exports
;; `local:pipe/svc' with `sum: async func(s: stream<u8>, f: future<u32>) ->
;; u32', which adds the stream's bytes and the future's value. The consumer's
;; `run' writes "abc" to a new stream and 7 to a new future, passes their
;; readers to `sum' through an async lowering, and answers its result: 301
;; (97 + 98 + 99 + 7) only if the provider reads the very ends the consumer
;; wrote. `self' writes a tuple to a future the consumer itself reads, which a
;; component may not do with a payload that is not a number.
;; Build: `scripts/build-wat-component-fixtures.sh`.
(component
  (component $provider
    (type $s8 (stream u8))
    (type $f32 (future u32))
    (core module $libc (memory (export "memory") 1))
    (core instance $libc (instantiate $libc))
    (alias core export $libc "memory" (core memory $mem))
    (core func $read8 (canon stream.read $s8 (memory $mem)))
    (core func $fread (canon future.read $f32 (memory $mem)))
    (core func $ret (canon task.return (result u32)))
    (core module $pm
      (import "" "memory" (memory 1))
      (import "" "read8" (func $read8 (param i32 i32 i32) (result i32)))
      (import "" "fread" (func $fread (param i32 i32) (result i32)))
      (import "" "ret" (func $ret (param i32)))
      (func (export "[async-lift]local:pipe/svc#sum") (param $s i32) (param $f i32)
        (local $r i32) (local $n i32) (local $i i32) (local $sum i32)
        (block $done
          (loop $more
            (local.set $r (call $read8 (local.get $s) (i32.const 64) (i32.const 16)))
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
        (drop (call $fread (local.get $f) (i32.const 128)))
        (call $ret (i32.add (local.get $sum) (i32.load (i32.const 128))))))
    (core instance $pmi (instantiate $pm (with "" (instance
      (export "memory" (memory $mem)) (export "read8" (func $read8))
      (export "fread" (func $fread)) (export "ret" (func $ret))))))
    (func $sum async (param "s" $s8) (param "f" $f32) (result u32)
      (canon lift (core func $pmi "[async-lift]local:pipe/svc#sum") async))
    (instance $svc (export "sum" (func $sum)))
    (export "local:pipe/svc" (instance $svc)))

  (component $consumer
    (type $s8 (stream u8))
    (type $f32 (future u32))
    (type $pair (tuple u32 u32))
    (type $fpair (future $pair))
    ;; The stream type comes from the enclosing component, as a toolchain
    ;; writes a type one interface takes from another.
    (import "local:pipe/svc" (instance $svc
      (alias outer $consumer $s8 (type $os8))
      (export "sum" (func async (param "s" $os8) (param "f" (future u32))
                    (result u32)))))
    (alias export $svc "sum" (func $sum))
    (core module $libc (memory (export "memory") 1))
    (core instance $libc (instantiate $libc))
    (alias core export $libc "memory" (core memory $mem))
    (core func $new8 (canon stream.new $s8))
    (core func $write8 (canon stream.write $s8 (memory $mem)))
    (core func $dropw8 (canon stream.drop-writable $s8))
    (core func $newf (canon future.new $f32))
    (core func $fwrite (canon future.write $f32 (memory $mem)))
    (core func $newp (canon future.new $fpair))
    (core func $pwrite (canon future.write $fpair async (memory $mem)))
    (core func $pread (canon future.read $fpair (memory $mem)))
    (core func $ret (canon task.return (result u32)))
    (core func $sum_l (canon lower (func $sum) async (memory $mem)))
    (core module $cm
      (import "" "memory" (memory 1))
      (import "" "new8" (func $new8 (result i64)))
      (import "" "write8" (func $write8 (param i32 i32 i32) (result i32)))
      (import "" "dropw8" (func $dropw8 (param i32)))
      (import "" "newf" (func $newf (result i64)))
      (import "" "fwrite" (func $fwrite (param i32 i32) (result i32)))
      (import "" "newp" (func $newp (result i64)))
      (import "" "pwrite" (func $pwrite (param i32 i32) (result i32)))
      (import "" "pread" (func $pread (param i32 i32) (result i32)))
      (import "" "ret" (func $ret (param i32)))
      (import "" "sum" (func $sum (param i32 i32 i32) (result i32)))
      (func (export "[async-lift]run")
        (local $s i64) (local $f i64)
        (local.set $s (call $new8))
        (i32.store (i32.const 128) (i32.const 0x00636261))
        (drop (call $write8 (i32.wrap_i64 (i64.shr_u (local.get $s) (i64.const 32)))
                            (i32.const 128) (i32.const 3)))
        (call $dropw8 (i32.wrap_i64 (i64.shr_u (local.get $s) (i64.const 32))))
        (local.set $f (call $newf))
        (i32.store (i32.const 136) (i32.const 7))
        (drop (call $fwrite (i32.wrap_i64 (i64.shr_u (local.get $f) (i64.const 32)))
                            (i32.const 136)))
        (drop (call $sum (i32.wrap_i64 (local.get $s)) (i32.wrap_i64 (local.get $f))
                         (i32.const 160)))
        (call $ret (i32.load (i32.const 160))))
      (func (export "[async-lift]self")
        (local $p i64)
        (local.set $p (call $newp))
        (i64.store (i32.const 192) (i64.const 0x0000000200000001))
        (drop (call $pwrite (i32.wrap_i64 (i64.shr_u (local.get $p) (i64.const 32)))
                            (i32.const 192)))
        (drop (call $pread (i32.wrap_i64 (local.get $p)) (i32.const 200)))
        (call $ret (i32.load (i32.const 200)))))
    (core instance $cmi (instantiate $cm (with "" (instance
      (export "memory" (memory $mem)) (export "new8" (func $new8))
      (export "write8" (func $write8)) (export "dropw8" (func $dropw8))
      (export "newf" (func $newf)) (export "fwrite" (func $fwrite))
      (export "newp" (func $newp)) (export "pwrite" (func $pwrite))
      (export "pread" (func $pread)) (export "ret" (func $ret))
      (export "sum" (func $sum_l))))))
    (func (export "run") async (result u32)
      (canon lift (core func $cmi "[async-lift]run") async))
    (func (export "self") async (result u32)
      (canon lift (core func $cmi "[async-lift]self") async)))

  (instance $p (instantiate $provider))
  (instance $c (instantiate $consumer
    (with "local:pipe/svc" (instance $p "local:pipe/svc"))))
  (alias export $c "run" (func $run))
  (alias export $c "self" (func $self))
  (export "run" (func $run))
  (export "self" (func $self)))
