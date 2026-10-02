wit_bindgen::generate!({ world: "asyncval", async: true });

use exports::run::Guest;
use wit_bindgen::rt::async_support::{FutureReader, StreamReader};

struct C;

impl Guest for C {
    async fn read_future(f: FutureReader<u32>) -> u32 {
        f.await
    }

    async fn sum_stream(s: StreamReader<u8>) -> u32 {
        let mut total: u32 = 0;
        let mut items = s;
        while let Some(b) = items.next().await {
            total = total.wrapping_add(b as u32);
        }
        total
    }

    async fn make_future(x: u8) -> FutureReader<u8> {
        let (tx, rx) = wit_future::new(|| 0);
        tx.write(x).await;
        rx
    }

    async fn make_stream(byte: u8, count: u32) -> StreamReader<u8> {
        let (mut tx, rx) = wit_stream::new();
        let data: Vec<u8> = core::iter::repeat(byte).take(count as usize).collect();
        tx.write_all(data).await;
        rx
    }
}

export!(C);
