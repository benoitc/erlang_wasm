// A real Rust CLI program: read a file named on the command line (default
// "input.txt") and write its bytes to stdout. Built for wasm32-wasip2 it is a
// real wasi:cli/command that reads through a preopened directory.
use std::io::Write;

fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "input.txt".to_string());
    match std::fs::read(&name) {
        Ok(bytes) => { std::io::stdout().write_all(&bytes).ok(); }
        Err(e) => { eprintln!("cannot read {}: {}", name, e); std::process::exit(1); }
    }
}
