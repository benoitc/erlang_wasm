wit_bindgen::generate!({ world: "asyncval", async: true });

use exports::run::Guest;

struct C;

impl Guest for C {
    async fn read_future(f: wit_bindgen::rt::async_support::FutureReader<u32>) -> u32 {
        f.await
    }

    async fn sum_stream(s: wit_bindgen::rt::async_support::StreamReader<u8>) -> u32 {
        let mut total: u32 = 0;
        let mut items = s;
        while let Some(b) = items.next().await {
            total = total.wrapping_add(b as u32);
        }
        total
    }
}

export!(C);
