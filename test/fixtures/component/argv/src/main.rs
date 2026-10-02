// Print argv[1..] one per line.
fn main() {
    for a in std::env::args().skip(1) {
        println!("{}", a);
    }
}
