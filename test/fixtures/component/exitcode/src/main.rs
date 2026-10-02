// Exit with the status given as argv[1] (default 0).
fn main() {
    let code: i32 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    std::process::exit(code);
}
