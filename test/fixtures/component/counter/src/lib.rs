wit_bindgen::generate!({ world: "runtime" });

use exports::example::counter::counters::{Guest, GuestCounter, Counter};
use std::cell::Cell;

pub struct MyCounter {
    v: Cell<u32>,
}

impl GuestCounter for MyCounter {
    fn new(init: u32) -> Self {
        MyCounter { v: Cell::new(init) }
    }
    fn increment(&self, by: u32) -> u32 {
        let n = self.v.get().wrapping_add(by);
        self.v.set(n);
        n
    }
    fn get(&self) -> u32 {
        self.v.get()
    }
}

struct C;

impl Guest for C {
    type Counter = MyCounter;

    fn make_counter(init: u32) -> Counter {
        Counter::new(MyCounter::new(init))
    }
}

export!(C);
