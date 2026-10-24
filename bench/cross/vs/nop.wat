;; The cheapest export: what a call from Erlang into the guest costs.
(module
  (func (export "nop") (param i32) (result i32) (local.get 0)))
