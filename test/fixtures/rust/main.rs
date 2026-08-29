use std::env;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::time::{Duration, Instant};

fn fib(n: u32) -> u64 { if n < 2 { n as u64 } else { fib(n-1) + fib(n-2) } }

fn main() {
    println!("hello from rust on wasm");

    let args: Vec<String> = env::args().collect();
    println!("args: {:?}", args);

    match env::var("MODE") {
        Ok(v)  => println!("MODE={}", v),
        Err(_) => println!("MODE unset"),
    }

    println!("fib(20)={}", fib(20));

    match fs::read_to_string("/data/note.txt") {
        Ok(s)  => println!("file: {}", s.trim()),
        Err(e) => println!("file error: {}", e),
    }

    // Must be refused: outside the preopened capability.
    match fs::read_to_string("/data/../secret/key.txt") {
        Ok(s)  => println!("ESCAPED: {}", s.trim()),
        Err(e) => println!("escape refused: {}", e.kind()),
    }

    // fd_readdir
    match fs::read_dir("/data") {
        Ok(rd) => {
            let mut names: Vec<String> = rd.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            println!("readdir: {:?}", names);
        }
        Err(e) => println!("readdir error: {}", e),
    }

    // positional read via Seek
    match fs::File::open("/data/note.txt") {
        Ok(mut f) => {
            let mut buf = [0u8; 8];
            f.seek(SeekFrom::Start(8)).unwrap();
            let n = f.read(&mut buf).unwrap();
            println!("seek+read: {:?}", String::from_utf8_lossy(&buf[..n]));
            println!("stream_position: {}", f.stream_position().unwrap());
        }
        Err(e) => println!("open error: {}", e),
    }

    // write, rename, then read back
    match fs::write("/data/tmp.txt", b"written by wasm") {
        Ok(()) => {
            match fs::rename("/data/tmp.txt", "/data/renamed.txt") {
                Ok(()) => match fs::read_to_string("/data/renamed.txt") {
                    Ok(s) => println!("rename ok: {}", s),
                    Err(e) => println!("read after rename failed: {}", e),
                },
                Err(e) => println!("rename error: {}", e),
            }
        }
        Err(e) => println!("write error: {}", e),
    }

    // thread::sleep needs poll_oneoff clock subscriptions
    let t0 = Instant::now();
    std::thread::sleep(Duration::from_millis(30));
    println!("slept: {}", t0.elapsed().as_millis() >= 25);

    let mut err = std::io::stderr();
    writeln!(err, "this goes to stderr").unwrap();

    std::process::exit(7);
}
