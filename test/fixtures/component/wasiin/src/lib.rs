wit_bindgen::generate!({ world: "app", generate_all });

use wasi::cli::stdin::get_stdin;

struct C;

impl Guest for C {
    fn slurp() -> Vec<u8> {
        let s = get_stdin();
        let mut out = Vec::new();
        loop {
            match s.blocking_read(4096) {
                Ok(chunk) => out.extend_from_slice(&chunk),
                Err(_) => break, // closed at end of stream
            }
        }
        out
    }
}

export!(C);
