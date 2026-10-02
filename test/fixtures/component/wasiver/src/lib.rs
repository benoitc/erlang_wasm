wit_bindgen::generate!({ world: "app", generate_all });
use wasi::random::random::get_random_u64;
struct C;
impl Guest for C {
    fn roll() -> u64 { get_random_u64() }
}
export!(C);
