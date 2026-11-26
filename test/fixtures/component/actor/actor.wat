;; The core module of the actor fixture, made a component against actor.wit by
;; scripts/build-wat-component-fixtures.sh.
;;
;; add(n)   adds n to a running total and posts added(total). A refused post
;;          is noted as 0xFFFFFF00 + the send-error case: ...00 full,
;;          ...01 closed.
;; added(n) notes n, so a post an actor makes to itself can be seen.
;; boom     traps.
(module
  (import "$root" "post" (func $post (param i32 i32 i32)))
  (import "$root" "note" (func $note (param i32)))
  (memory (export "memory") 1)
  (global $total (mut i32) (i32.const 0))
  (func (export "handle") (param $case i32) (param $n i32)
    (block $boom
      (block $added
        (block $add
          (br_table $add $added $boom (local.get $case)))
        (global.set $total (i32.add (global.get $total) (local.get $n)))
        ;; post's result<_, send-error> comes back at 16: the case, then
        ;; the error.
        (call $post (i32.const 1) (global.get $total) (i32.const 16))
        (if (i32.load8_u (i32.const 16))
          (then
            (call $note (i32.or (i32.const 0xFFFFFF00)
                                (i32.load8_u (i32.const 17))))))
        (return))
      (call $note (local.get $n))
      (return))
    unreachable))
