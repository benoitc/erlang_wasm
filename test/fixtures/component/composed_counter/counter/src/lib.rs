#[allow(warnings)]
mod bindings;
use bindings::exports::test::counter::ops::{Guest, GuestCounter};
use std::cell::Cell;

struct Component;
struct Counter { n: Cell<u32> }

impl Guest for Component {
    type Counter = Counter;
}

impl GuestCounter for Counter {
    fn new(init: u32) -> Self {
        Counter { n: Cell::new(init) }
    }
    fn increment(&self) -> u32 {
        let v = self.n.get() + 1;
        self.n.set(v);
        v
    }
}

bindings::export!(Component with_types_in bindings);
