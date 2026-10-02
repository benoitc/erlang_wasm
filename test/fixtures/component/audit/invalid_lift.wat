(component (core module $m (func (export "run") (result f64) f64.const 1)) (core instance $i (instantiate $m)) (func (export "run") (result u32) (canon lift (core func $i "run"))))
