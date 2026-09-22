wit_bindgen::generate!({ world: "app", generate_all });
use wasi::filesystem::preopens::get_directories;
use wasi::filesystem::types::{OpenFlags, PathFlags, DescriptorFlags, DescriptorType};
struct C;
impl Guest for C {
    fn cat(name: String) -> Vec<u8> {
        let dirs = get_directories();
        let (dir, _) = &dirs[0];
        let f = dir.open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).unwrap();
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
        let dirs = get_directories();
        let (dir, _) = &dirs[0];
        dir.open_at(PathFlags::empty(), &name, OpenFlags::empty(), DescriptorFlags::READ).is_ok()
    }
    fn root_is_dir() -> bool {
        let dirs = get_directories();
        let (dir, _) = &dirs[0];
        matches!(dir.get_type(), Ok(DescriptorType::Directory))
    }
}
export!(C);
