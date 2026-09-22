wit_bindgen::generate!({ world: "app" });

use wasi::clocks::monotonic_clock;
use wasi::clocks::wall_clock;

struct C;

impl Guest for C {
    fn mono_now() -> u64 { monotonic_clock::now() }
    fn mono_res() -> u64 { monotonic_clock::resolution() }
    fn wall_now() -> Datetime { wall_clock::now() }
    fn wall_res() -> Datetime { wall_clock::resolution() }
}

export!(C);
