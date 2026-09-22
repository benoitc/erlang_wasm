wit_bindgen::generate!({ world: "app", generate_all });

use wasi::filesystem::preopens::get_directories;
use wasi::filesystem::types::{OpenFlags, PathFlags, DescriptorFlags, DescriptorType};

struct C;

fn root() -> wasi::filesystem::types::Descriptor {
    let mut dirs = get_directories();
    dirs.remove(0).0
}

impl Guest for C {
    fn cat(name: String) -> Vec<u8> {
        let f = root().open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).unwrap();
        let mut out = Vec::new();
        let mut off = 0u64;
        loop {
            let (chunk, eof) = f.read(4096, off).unwrap();
            off += chunk.len() as u64;
            out.extend_from_slice(&chunk);
            if eof { break; }
        }
        out
    }
    fn present(name: String) -> bool {
        root().open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).is_ok()
    }
    fn root_is_dir() -> bool {
        matches!(root().get_type(), Ok(DescriptorType::Directory))
    }
    fn size(name: String) -> u64 {
        let f = root().open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).unwrap();
        f.stat().unwrap().size
    }
    fn entries() -> Vec<String> {
        let des = root().read_directory().unwrap();
        let mut names = Vec::new();
        while let Ok(Some(e)) = des.read_directory_entry() {
            names.push(e.name);
        }
        names
    }
    fn slurp(name: String) -> Vec<u8> {
        let f = root().open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).unwrap();
        let s = f.read_via_stream(0).unwrap();
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
