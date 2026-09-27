#[allow(warnings)]
mod bindings;
use bindings::test::counter::ops::Counter;
use bindings::Guest;

struct Component;

impl Guest for Component {
    fn run() -> u32 {
        let c = Counter::new(41);
        c.increment()
    }
}

bindings::export!(Component with_types_in bindings);
