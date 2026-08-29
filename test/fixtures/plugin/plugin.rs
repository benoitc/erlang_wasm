// A plugin, compiled to wasm and run untrusted. See examples/plugin_worker.erl.
//
// This is the compiled shape: the logic is fixed at build time and erlang_wasm
// interprets it directly, so there is one level of interpretation rather than
// two. Compare examples/script_worker.erl, which ships an interpreter instead.
//
// A reactor, not a command: it has no `_start` and never exits. The host writes
// a record into the buffer this exports, calls `normalise`, and reads back what
// it left there.

static mut BUF: [u8; 4096] = [0; 4096];

/// Where the host should write the record. A fixed buffer keeps the interface
/// to two calls and no allocator.
#[no_mangle]
pub extern "C" fn buffer() -> u32 {
    &raw const BUF as u32
}

#[no_mangle]
pub extern "C" fn capacity() -> u32 {
    4096
}

/// Validate and normalise `len` bytes: trim, lowercase, and require an `@`
/// with something either side. Returns the new length, or -1 if it is not a
/// record this plugin accepts.
#[no_mangle]
pub extern "C" fn normalise(len: u32) -> i32 {
    let n = len as usize;
    if n > 4096 {
        return -1;
    }
    let bytes = unsafe { &mut *(&raw mut BUF) };
    // ASCII only, on purpose: pulling in Unicode case tables would take this
    // from a few kilobytes to two megabytes, and a plugin should be small.
    let mut start = 0usize;
    let mut end = n;
    while start < end && bytes[start].is_ascii_whitespace() {
        start += 1;
    }
    while end > start && bytes[end - 1].is_ascii_whitespace() {
        end -= 1;
    }
    let len = end - start;
    bytes.copy_within(start..end, 0);
    let mut at = None;
    let mut dot_after_at = false;
    for i in 0..len {
        bytes[i] = bytes[i].to_ascii_lowercase();
        match bytes[i] {
            b'@' if at.is_none() => at = Some(i),
            b'.' if at.is_some() => dot_after_at = true,
            _ => {}
        }
    }
    match at {
        Some(i) if i > 0 && i + 1 < len && dot_after_at => len as i32,
        _ => -1,
    }
}

/// Deliberately reachable, so a worker's timeout has something to interrupt.
#[no_mangle]
pub extern "C" fn spin() -> i32 {
    let mut i: u64 = 0;
    loop {
        i = i.wrapping_add(1);
        unsafe { core::ptr::read_volatile(&raw const BUF[0]) };
        core::hint::black_box(i);
    }
}
