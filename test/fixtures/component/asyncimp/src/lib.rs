wit_bindgen::generate!({ world: "asyncimp", async: true });

use local::asyncimp::host::compute;
use exports::run::Guest;

struct C;

impl Guest for C {
    async fn call_compute(x: u32) -> u32 {
        compute(x).await + 1
    }
}

export!(C);
