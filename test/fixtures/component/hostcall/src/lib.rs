wit_bindgen::generate!({ world: "app" });

use example::host::clock::{now, add};

struct C;

impl Guest for C {
    fn read_now() -> u64 { now() }
    fn read_add(a: u32, b: u32) -> u32 { add(a, b) }
}

export!(C);
