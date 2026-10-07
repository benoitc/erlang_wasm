;; The guest of `fake_pages_adapter': a request names the 4 KiB pages it
;; writes, so a case knows exactly which pages a worker should learn.
;;
;; `init' marks the first word of each of the 64 pages, so every page of the
;; captured image is the image's own bytes rather than zeros. `touch' bumps a
;; counter in page `p' and answers it: 1 from every fresh instance.
;;
;; Built with `wasm-tools parse pages.wat -o pages.wasm'.
(module
  (memory (export "memory") 4)
  (func (export "init")
    (local $p i32)
    (loop $mark
      (i32.store (i32.mul (local.get $p) (i32.const 4096))
                 (i32.add (local.get $p) (i32.const 1)))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br_if $mark (i32.lt_u (local.get $p) (i32.const 64)))))
  (func (export "ready") (result i32)
    (i32.const 1))
  (func (export "touch") (param $p i32) (result i32)
    (local $a i32)
    (local.set $a (i32.add (i32.mul (local.get $p) (i32.const 4096))
                           (i32.const 8)))
    (i32.store (local.get $a) (i32.add (i32.load (local.get $a)) (i32.const 1)))
    (i32.load (local.get $a))))
