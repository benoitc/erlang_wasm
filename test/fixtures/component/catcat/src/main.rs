// Copy stdin to stdout verbatim.
use std::io::{Read, Write};
fn main() {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf).ok();
    std::io::stdout().write_all(&buf).ok();
}
