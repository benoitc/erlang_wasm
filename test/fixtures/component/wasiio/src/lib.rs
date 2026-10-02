wit_bindgen::generate!({ world: "app", generate_all });

use wasi::cli::stdout::get_stdout;

struct C;

impl Guest for C {
    fn emit(bytes: Vec<u8>) {
        let s = get_stdout();
        let _ = s.blocking_write_and_flush(&bytes);
    }
}

export!(C);
