(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func $environ_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_prestat_get"
    (func $fd_prestat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "random_get"
    (func $random_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "clock_time_get"
    (func $clock_time_get (param i32 i64 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "hello from wasm\n")

  ;; write "hello from wasm\n" to stdout via an iovec at 8
  (func (export "say") (result i32)
    (i32.store (i32.const 8) (i32.const 100))   ;; iov.buf
    (i32.store (i32.const 12) (i32.const 16))   ;; iov.len
    (call $fd_write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 20)))

  (func (export "nwritten") (result i32) (i32.load (i32.const 20)))

  (func (export "argc") (result i32)
    (drop (call $args_sizes_get (i32.const 8) (i32.const 12)))
    (i32.load (i32.const 8)))

  (func (export "envc") (result i32)
    (drop (call $environ_sizes_get (i32.const 8) (i32.const 12)))
    (i32.load (i32.const 8)))

  ;; open path (at 200, len given) under preopen fd 3, return errno
  (func (export "open") (param i32 i32) (result i32)
    (call $path_open (i32.const 3) (i32.const 0) (local.get 0) (local.get 1)
                     (i32.const 0) (i64.const -1) (i64.const -1)
                     (i32.const 0) (i32.const 24)))

  (func (export "opened_fd") (result i32) (i32.load (i32.const 24)))

  (func (export "read_opened") (param i32) (result i32)
    (i32.store (i32.const 8) (i32.const 300))
    (i32.store (i32.const 12) (i32.const 64))
    (call $fd_read (local.get 0) (i32.const 8) (i32.const 1) (i32.const 28)))

  (func (export "nread") (result i32) (i32.load (i32.const 28)))
  (func (export "byte") (param i32) (result i32) (i32.load8_u (local.get 0)))
  (func (export "store_byte") (param i32 i32) (i32.store8 (local.get 0) (local.get 1)))

  (func (export "prestat") (result i32)
    (call $fd_prestat_get (i32.const 3) (i32.const 32)))

  (func (export "rand") (result i32) (call $random_get (i32.const 400) (i32.const 16)))
  (func (export "clock") (param i32) (result i32)
    (call $clock_time_get (local.get 0) (i64.const 1000) (i32.const 40)))
  (func (export "quit") (param i32) (call $proc_exit (local.get 0)))
)
