;; Garbage collection: a recursive group, subtypes final and open, struct and
;; array types with packed fields, and the instructions that build, read,
;; test and cast them.
(module
  (rec
    (type $node (sub (struct (field $val (mut i32)) (field $next (ref null $node)))))
    (type $leaf (sub final $node (struct (field $val (mut i32)) (field $next (ref null $node))))))
  (type $bytes (array (mut i8)))
  (type $pair (struct (field i16) (field f64)))
  (func (export "sum") (param $n (ref null $node)) (result i32)
    (local $acc i32)
    (block $done
      (loop $walk
        (br_if $done (ref.is_null (local.get $n)))
        (local.set $acc (i32.add (local.get $acc)
                                 (struct.get $node $val (local.get $n))))
        (local.set $n (struct.get $node $next (local.get $n)))
        (br $walk)))
    (local.get $acc))
  (func (export "make") (result (ref $leaf))
    (struct.new $leaf (i32.const 1) (ref.null $node)))
  (func (export "bytes") (result i32)
    (local $a (ref $bytes))
    (local.set $a (array.new $bytes (i32.const 7) (i32.const 3)))
    (array.set $bytes (local.get $a) (i32.const 0) (i32.const 200))
    (i32.add (array.get_u $bytes (local.get $a) (i32.const 0))
             (array.len (local.get $a))))
  (func (export "pair") (result i32)
    (struct.get_s $pair 0 (struct.new $pair (i32.const -1) (f64.const 2))))
  (func (export "casts") (param $r anyref) (result i32)
    (block $is_node (result (ref $node))
      (br_on_cast $is_node anyref (ref $node) (local.get $r))
      (drop)
      (return (ref.test (ref i31) (local.get $r))))
    (drop)
    (i31.get_s (ref.i31 (i32.const -5))))
  (func (export "views") (param $e externref) (result externref)
    (extern.convert_any (any.convert_extern (local.get $e)))))
