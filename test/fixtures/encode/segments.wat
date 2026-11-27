;; Every element segment form, every data segment form and every limits
;; shape the encoder chooses between, one of each.
(module
  (type $v (func))
  (func $f0)
  (func $f1)
  (table $t0 2 funcref)
  (table $t1 1 4 funcref)
  (table $t2 1 (ref func) (ref.func $f0))
  (memory $m0 1)
  (memory $m1 1 2)
  (memory $m2 i64 1 3)
  (memory $m3 1 4 shared)
  ;; function indices: table 0, passive, another table, declarative
  (elem (i32.const 0) $f0 $f1)
  (elem func $f0)
  (elem (table $t1) (i32.const 0) func $f1)
  (elem declare func $f0)
  ;; expressions: funcref on table 0, passive, another table, declarative
  (elem (i32.const 0) funcref (ref.null func) (ref.func $f0))
  (elem funcref (ref.null func))
  (elem (table $t1) (i32.const 1) funcref (ref.func $f1))
  (elem declare funcref (ref.func $f1))
  ;; memory 0, passive, another memory
  (data (i32.const 0) "a")
  (data "passive")
  (data (memory $m1) (i32.const 0) "b")
  (func (export "use") (param i32)
    (memory.init 1 (i32.const 0) (i32.const 0) (i32.const 1))
    (data.drop 1)
    (i64.store $m2 offset=8 (i64.const 0) (i64.const 7))
    (drop (i32.load $m1 (i32.const 4)))))
