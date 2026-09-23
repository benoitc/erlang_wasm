// Write a file under the preopened dir, then read it back to stdout.
use std::io::Write;
fn main() {
    std::fs::write("out.txt", b"written by the guest\n").expect("write");
    let back = std::fs::read("out.txt").expect("read");
    std::io::stdout().write_all(&back).ok();
}
