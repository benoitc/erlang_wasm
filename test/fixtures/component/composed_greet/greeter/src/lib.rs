#[allow(warnings)]
mod bindings;
use bindings::exports::test::greet::greeter::Guest;

struct Component;

impl Guest for Component {
    fn greet(name: String) -> String {
        format!("hello, {}", name)
    }
}

bindings::export!(Component with_types_in bindings);
