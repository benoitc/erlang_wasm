wit_bindgen::generate!({ world: "app" });

use wasi::random::random::{get_random_u64, get_random_bytes};

struct C;

impl Guest for C {
    fn roll() -> u64 { get_random_u64() }
    fn bytes(n: u32) -> Vec<u8> { get_random_bytes(n as u64) }
}

export!(C);
