;; What a program built with wasi-libc's cooperative threads asks of the
;; host, one export for each: async imports lowered without the async option,
;; context slots that belong to a thread, a `realloc' that runs with slots of
;; its own, a lift in a core that has no memory, a thread that calls through
;; another core's table, and a thread that waits while the others run.
(component
  (import "local:coop/host" (instance $host
    (export "double" (func async (param "x" u32) (result u32)))
    (export "later" (func async (param "x" u32) (result u32)))
    (export "len" (func async (param "s" string) (result u32)))
    (export "name" (func (result string)))
    (export "note" (func (param "x" u32)))))

  ;; The memory and the table the threads start from.
  (core module $libc
    (memory (export "mem") 1)
    (table (export "t") 4 funcref))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "mem" (core memory $mem))
  (alias core export $libc "t" (core table $t))

  (core func $ctx_get (canon context.get i32 0))
  (core func $ctx_set (canon context.set i32 0))
  (core type $ft (func (param i32)))
  (core func $new (canon thread.new-indirect $ft (core table $t)))
  (core func $ytr (canon thread.yield-then-resume))
  (core func $yield (canon thread.yield))
  (core func $resume_later (canon thread.resume-later))
  (core func $ws_new (canon waitable-set.new))
  (core func $join (canon waitable.join))
  (core func $wait (canon waitable-set.wait (memory $mem)))
  (type $f32 (future u32))
  (core func $fnew (canon future.new $f32))
  (core func $fread (canon future.read $f32 async (memory $mem)))
  (core func $fwrite (canon future.write $f32 (memory $mem)))

  (alias export $host "double" (func $double))
  (alias export $host "later" (func $later))
  (alias export $host "len" (func $len))
  (alias export $host "name" (func $name))
  (alias export $host "note" (func $note))
  (core func $double_l (canon lower (func $double)))
  (core func $later_l (canon lower (func $later)))
  (core func $len_l (canon lower (func $len) (memory $mem)))
  (core func $note_l (canon lower (func $note)))

  ;; `note' and `name' reached as wit-component reaches an import: through a
  ;; table in a module of its own, filled once the main module is there. The
  ;; lowering of `name' needs that module's allocator.
  (core module $shim
    (table (export "imports") 2 funcref)
    (type $n (func (param i32)))
    (func (export "0") (param i32)
      (call_indirect (type $n) (local.get 0) (i32.const 0)))
    (func (export "1") (param i32)
      (call_indirect (type $n) (local.get 0) (i32.const 1))))
  (core instance $shim (instantiate $shim))

  (core module $m
    (import "" "mem" (memory 1))
    (import "" "t" (table 4 funcref))
    (import "" "ctx_get" (func $ctx_get (result i32)))
    (import "" "ctx_set" (func $ctx_set (param i32)))
    (import "" "new" (func $new (param i32 i32) (result i32)))
    (import "" "ytr" (func $ytr (param i32) (result i32)))
    (import "" "yield" (func $yield (result i32)))
    (import "" "resume_later" (func $resume_later (param i32)))
    (import "" "ws_new" (func $ws_new (result i32)))
    (import "" "join" (func $join (param i32 i32)))
    (import "" "wait" (func $wait (param i32 i32) (result i32)))
    (import "" "fnew" (func $fnew (result i64)))
    (import "" "fread" (func $fread (param i32 i32) (result i32)))
    (import "" "fwrite" (func $fwrite (param i32 i32) (result i32)))
    (import "" "double" (func $double (param i32) (result i32)))
    (import "" "later" (func $later (param i32) (result i32)))
    (import "" "len" (func $len (param i32 i32) (result i32)))
    (import "" "name" (func $name (param i32)))
    (import "" "note" (func $note (param i32)))

    (data (i32.const 128) "hello")
    (global $slot (mut i32) (i32.const -1))
    (global $seen (mut i32) (i32.const -1))

    ;; The allocator, as wasi-libc's behaves: it notes the stack pointer slot
    ;; it starts with and leaves the slot at zero.
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (global.set $seen (call $ctx_get))
      (call $ctx_set (i32.const 0))
      (i32.const 1024))
    (global $spins (mut i32) (i32.const 0))

    ;; The threads' start functions, by their index in the table.
    (elem (i32.const 0) $t_note $t_ctx $t_write $t_spin)
    (func $t_note (param i32) (call $note (local.get 0)))
    (func $t_ctx (param i32)
      (global.set $slot (call $ctx_get))
      (call $ctx_set (i32.const 22)))
    ;; Resolve the future whose writable end is the argument, with 99.
    (func $t_write (param $w i32)
      (i32.store (i32.const 200) (i32.const 99))
      (drop (call $fwrite (local.get $w) (i32.const 200))))
    ;; The same, then yield for ever, counting the turns.
    (func $t_spin (param $w i32)
      (call $t_write (local.get $w))
      (loop $again
        (global.set $spins (i32.add (global.get $spins) (i32.const 1)))
        (drop (call $yield))
        (br_if $again (i32.lt_u (global.get $spins) (i32.const 1000)))))

    ;; double(x), later(x): an async import called as a blocking function.
    (func (export "double") (param i32) (result i32) (call $double (local.get 0)))
    (func (export "later") (param i32) (result i32) (call $later (local.get 0)))
    ;; len-hello(): the import reads its string from this memory.
    (func (export "len-hello") (result i32) (call $len (i32.const 128) (i32.const 5)))

    ;; realloc-slots(): 1000 times the slot after a call whose result the host
    ;; allocates, plus the slot `realloc' saw. 42000: the caller's 42 is back
    ;; and `realloc' started from zero.
    (func (export "realloc-slots") (result i32)
      (call $ctx_set (i32.const 42))
      (call $name (i32.const 64))
      (i32.add (i32.mul (call $ctx_get) (i32.const 1000)) (global.get $seen)))

    ;; thread-note(x): a thread gives x to the host.
    (func (export "thread-note") (param i32) (result i32)
      (drop (call $ytr (call $new (i32.const 0) (local.get 0))))
      (i32.const 1))

    ;; thread-slots(): 100 times this thread's slot after another thread set
    ;; its own, plus the slot that thread started with. 1100.
    (func (export "thread-slots") (result i32)
      (call $ctx_set (i32.const 11))
      (drop (call $ytr (call $new (i32.const 1) (i32.const 0))))
      (i32.add (i32.mul (call $ctx_get) (i32.const 100)) (global.get $slot)))

    ;; Wait for a future that only the thread started from table index
    ;; `start' resolves, and return its value.
    (func $await (param $start i32) (result i32)
      (local $pair i64) (local $r i32) (local $set i32)
      (local.set $pair (call $fnew))
      (local.set $r (i32.wrap_i64 (local.get $pair)))
      (drop (call $fread (local.get $r) (i32.const 208)))
      (local.set $set (call $ws_new))
      (call $join (local.get $r) (local.get $set))
      (call $resume_later
        (call $new (local.get $start)
                   (i32.wrap_i64 (i64.shr_u (local.get $pair) (i64.const 32)))))
      (drop (call $wait (local.get $set) (i32.const 216)))
      (i32.load (i32.const 208)))
    (func (export "wait-for-thread") (result i32) (call $await (i32.const 2)))
    ;; 1000 times the value, plus the turns the yielding thread had taken
    ;; when this one went on. 99001.
    (func (export "wait-beside-a-yielder") (result i32)
      (i32.add (i32.mul (call $await (i32.const 3)) (i32.const 1000))
               (global.get $spins))))
  (core instance $i (instantiate $m (with "" (instance
    (export "mem" (memory $mem)) (export "t" (table $t))
    (export "ctx_get" (func $ctx_get)) (export "ctx_set" (func $ctx_set))
    (export "new" (func $new)) (export "ytr" (func $ytr))
    (export "yield" (func $yield)) (export "resume_later" (func $resume_later))
    (export "ws_new" (func $ws_new)) (export "join" (func $join))
    (export "wait" (func $wait)) (export "fnew" (func $fnew))
    (export "fread" (func $fread)) (export "fwrite" (func $fwrite))
    (export "double" (func $double_l)) (export "later" (func $later_l))
    (export "len" (func $len_l)) (export "name" (func $shim "1"))
    (export "note" (func $shim "0"))))))

  (alias core export $i "cabi_realloc" (core func $realloc))
  (core func $name_l (canon lower (func $name) (memory $mem) (realloc $realloc)))
  (core module $fixup
    (import "" "imports" (table 2 funcref))
    (import "" "note" (func $note (param i32)))
    (import "" "name" (func $name (param i32)))
    (elem (i32.const 0) $note $name))
  (core instance $fixup (instantiate $fixup (with "" (instance
    (export "imports" (table $shim "imports"))
    (export "note" (func $note_l)) (export "name" (func $name_l))))))

  ;; `len-hello' again, lifted from a module that has no memory, as
  ;; wit-component wraps an export.
  (core module $wrap
    (import "" "len-hello" (func $inner (result i32)))
    (func (export "hook") (result i32) (call $inner)))
  (core instance $wrap (instantiate $wrap (with "" (instance
    (export "len-hello" (func $i "len-hello"))))))

  (func (export "double") (param "x" u32) (result u32)
    (canon lift (core func $i "double")))
  (func (export "later") (param "x" u32) (result u32)
    (canon lift (core func $i "later")))
  (func (export "len-hello") (result u32) (canon lift (core func $i "len-hello")))
  (func (export "len-hello-wrapped") (result u32) (canon lift (core func $wrap "hook")))
  (func (export "realloc-slots") (result u32) (canon lift (core func $i "realloc-slots")))
  (func (export "thread-note") (param "x" u32) (result u32)
    (canon lift (core func $i "thread-note")))
  (func (export "thread-slots") (result u32) (canon lift (core func $i "thread-slots")))
  (func (export "wait-for-thread") (result u32)
    (canon lift (core func $i "wait-for-thread")))
  (func (export "wait-beside-a-yielder") (result u32)
    (canon lift (core func $i "wait-beside-a-yielder"))))
