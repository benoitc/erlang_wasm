// Print the value of the environment variable named by argv[1] (or "GREETING").
fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "GREETING".to_string());
    match std::env::var(&name) {
        Ok(v) => println!("{}", v),
        Err(_) => { eprintln!("unset: {}", name); std::process::exit(3); }
    }
}
