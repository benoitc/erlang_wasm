#[allow(warnings)]
mod bindings;
use bindings::test::greet::greeter::greet;
use bindings::Guest;

struct Component;

impl Guest for Component {
    fn run() -> String {
        greet("wasm")
    }
}

bindings::export!(Component with_types_in bindings);
