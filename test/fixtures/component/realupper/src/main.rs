// A real, unmodified Rust CLI program: read stdin, upper-case it, write stdout.
// Built for wasm32-wasip2, this is a real wasi:cli/command component that both
// wasmtime and erlang_wasm run. No WIT, no bindings.
use std::io::{Read, Write};

fn main() {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).ok();
    let text = String::from_utf8_lossy(&input);
    std::io::stdout().write_all(text.to_uppercase().as_bytes()).ok();
}
