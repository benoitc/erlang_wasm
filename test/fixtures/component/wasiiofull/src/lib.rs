wit_bindgen::generate!({ world: "app", generate_all });

use wasi::cli::stdout::get_stdout;
use wasi::cli::stdin::get_stdin;
use wasi::io::poll::poll;

struct C;

impl Guest for C {
    fn pump(bytes: Vec<u8>) -> u64 {
        let s = get_stdout();
        let budget = s.check_write().unwrap();
        s.write(&bytes).unwrap();
        s.blocking_flush().unwrap();
        budget
    }
    fn peek() -> bool {
        let s = get_stdin();
        let p = s.subscribe();
        let ready = poll(&[&p]);
        !ready.is_empty()
    }
    fn drain() -> Vec<u8> {
        let s = get_stdin();
        let mut out = Vec::new();
        loop {
            match s.blocking_read(4096) {
                Ok(c) => out.extend_from_slice(&c),
                Err(_) => break,
            }
        }
        out
    }
}

export!(C);
