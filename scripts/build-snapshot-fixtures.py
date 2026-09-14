#!/usr/bin/env python3
"""Emit the small modules `wasm_snapshot_SUITE` needs.

They are committed, because they are a few hundred bytes each and because a CI
job that needs a WebAssembly toolchain is a CI job that can fail on the network
like any other. This regenerates and verifies them; it does not run at test
time.

Written by hand rather than through a toolchain for the same reason: the suite
needs modules with shapes a normal compiler never emits, such as one whose only
purpose is to import a memory, and hand-emitting four of them is smaller than
depending on wat2wasm to be installed.
"""
import struct, sys, os

def u32(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            return out

def i32(n):                     # signed LEB128
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if (n == 0 and not (b & 0x40)) or (n == -1 and (b & 0x40)):
            return out + bytes([b])
        out += bytes([b | 0x80])

def vec(items):
    return u32(len(items)) + b"".join(items)

def section(sid, payload):
    return bytes([sid]) + u32(len(payload)) + payload

def name(s):
    b = s.encode()
    return u32(len(b)) + b

def functype(params, results):
    return b"\x60" + vec([bytes([p]) for p in params]) + vec([bytes([r]) for r in results])

I32 = 0x7F
MAGIC = b"\x00asm" + struct.pack("<I", 1)

def module(types=(), imports=(), funcs=(), tables=(), mems=(), globals_=(),
           exports=(), start=None, elems=(), code=(), datas=()):
    out = MAGIC
    if types:   out += section(1, vec(list(types)))
    if imports: out += section(2, vec(list(imports)))
    if funcs:   out += section(3, vec([u32(f) for f in funcs]))
    if tables:  out += section(4, vec(list(tables)))
    if mems:    out += section(5, vec(list(mems)))
    if globals_:out += section(6, vec(list(globals_)))
    if exports: out += section(7, vec(list(exports)))
    if start is not None: out += section(8, u32(start))
    if elems:   out += section(9, vec(list(elems)))
    if code:    out += section(10, vec(list(code)))
    # 11 after 10: the section order is part of the format, and emitting data
    # before code is `section_out_of_order`.
    if datas:   out += section(11, vec(list(datas)))
    return out

def active_data(offset, payload):
    return b"\x00" + b"\x41" + i32(offset) + END + u32(len(payload)) + payload

def body(locals_, instrs):
    b = vec(locals_) + instrs + b"\x0b"
    return u32(len(b)) + b

def export(nm, kind, idx):
    return name(nm) + bytes([kind]) + u32(idx)

END = b"\x0b"

# ---------------------------------------------------------------- reactor ---
# memory 1, two mutable globals, a table holding a self funcref, and the
# init/handle pair a snapshot needs.
def reactor():
    types = [functype([], []), functype([], [I32])]
    # funcs: 0 answer()->i32, 1 init(), 2 handle()->i32, 3 ready()->i32,
    #        4 through_table()->i32, 5 spin()
    funcs = [1, 0, 1, 1, 1, 0]
    tables = [b"\x70\x00" + u32(2)]                     # funcref, min 2
    mems = [b"\x00" + u32(1)]                           # min 1 page
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END,   # $ready mut i32
                bytes([I32, 0x01]) + b"\x41" + i32(0) + END]   # $count mut i32
    exports = [export("memory", 0x02, 0),
               export("init", 0x00, 1), export("handle", 0x00, 2),
               export("ready", 0x00, 3), export("through_table", 0x00, 4),
               # A capture that never finishes has to be reachable from a
               # fixture, or `capture_timeout` is a setting no case can watch
               # do anything.
               export("spin", 0x00, 5)]
    # A declarative element segment, so `ref.func` may name func 0.
    elems = [b"\x03\x00" + vec([u32(0)])]
    answer = body([], b"\x41" + i32(42))
    init = body([],
                b"\x41" + i32(1) + b"\x24" + u32(0) +          # global.set 0
                b"\x41" + i32(0) + b"\x41" + i32(1234) + b"\x36\x02\x00" +
                b"\x41" + i32(0) + b"\xd2" + u32(0) + b"\x26" + u32(0))
    handle = body([],
                  b"\x23" + u32(1) + b"\x41" + i32(1) + b"\x6a" +
                  b"\x24" + u32(1) +
                  b"\x23" + u32(1) +
                  b"\x41" + i32(0) + b"\x28\x02\x00" + b"\x6a")
    ready = body([], b"\x23" + u32(0))
    through = body([], b"\x41" + i32(0) + b"\x11" + u32(1) + b"\x00")
    spin = body([], b"\x03\x40" + b"\x0c" + u32(0) + b"\x0b")   # loop { br 0 }
    return module(types=types, funcs=funcs, tables=tables, mems=mems,
                  globals_=globals_, exports=exports, elems=elems,
                  code=[answer, init, handle, ready, through, spin])

# ---------------------------------------------------------------- started ---
# A start function whose effect is a **host call**, not a global. A global
# would be overwritten by the image on restore, so a start function that ran
# twice would leave no trace: the only evidence that survives a restore is an
# effect outside the guest.
def started():
    types = [functype([], []), functype([], [I32])]
    imports = [name("env") + name("tick") + b"\x00" + u32(0)]
    funcs = [0, 0, 1]                       # 1 $start, 2 init, 3 starts
    mems = [b"\x00" + u32(1)]
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END]
    exports = [export("memory", 0x02, 0), export("init", 0x00, 2),
               export("starts", 0x00, 3)]
    start_fn = body([], b"\x10" + u32(0) +                       # call $tick
                        b"\x23" + u32(0) + b"\x41" + i32(1) + b"\x6a" +
                        b"\x24" + u32(0))
    init = body([], b"")
    starts = body([], b"\x23" + u32(0))
    return module(types=types, imports=imports, funcs=funcs, mems=mems,
                  globals_=globals_, exports=exports, start=1,
                  code=[start_fn, init, starts])

# --------------------------------------------------------- imports_memory ---
def imports_memory():
    types = [functype([], [])]
    imports = [name("env") + name("mem") + b"\x02" + b"\x00" + u32(1)]
    funcs = [0]
    exports = [export("init", 0x00, 0)]
    return module(types=types, imports=imports, funcs=funcs, exports=exports,
                  code=[body([], b"")])

# --------------------------------------------------------- holds_external ---
# Puts an *imported* function into its table, which is a reference to another
# instance and cannot be captured.
def holds_external():
    types = [functype([], [I32]), functype([], [])]
    imports = [name("env") + name("f") + b"\x00" + u32(0)]
    funcs = [1, 0, 1]              # 1 init, 2 through_table, 3 block
    tables = [b"\x70\x00" + u32(1)]
    exports = [export("init", 0x00, 1), export("through_table", 0x00, 2),
               export("block", 0x00, 3)]
    elems = [b"\x03\x00" + vec([u32(0)])]
    init = body([], b"\x41" + i32(0) + b"\xd2" + u32(0) + b"\x26" + u32(0))
    through = body([], b"\x41" + i32(0) + b"\x11" + u32(0) + b"\x00")
    # Calls the import and discards it, so the host decides how long the call
    # lasts. That is what lets a case hold a call open while it tries to
    # capture.
    block = body([], b"\x10" + u32(0) + b"\x1a")
    return module(types=types, imports=imports, funcs=funcs, tables=tables,
                  exports=exports, elems=elems, code=[init, through, block])

# ------------------------------------------------------------- wasi_opener ---
# Opens a file during init and keeps it, which is what makes it unsnapshottable:
# a live descriptor is not reconstructible and the WASI hook refuses it.
def wasi_opener():
    types = [functype([], []),
             functype([I32] * 4 + [I32] + [0x7E, 0x7E] + [I32, I32], [I32])]
    imports = [name("wasi_snapshot_preview1") + name("path_open")
               + b"\x00" + u32(1)]
    funcs = [0]
    mems = [b"\x00" + u32(1)]
    exports = [export("memory", 0x02, 0), export("init", 0x00, 1)]
    data = [b"\x00" + b"\x41" + i32(200) + END + u32(9) + b"input.txt"]
    init = body([],
                b"\x41" + i32(3) + b"\x41" + i32(0) +
                b"\x41" + i32(200) + b"\x41" + i32(9) +
                b"\x41" + i32(0) +
                b"\x42" + i32(2) + b"\x42" + i32(2) +
                b"\x41" + i32(0) + b"\x41" + i32(300) +
                b"\x10" + u32(0) + b"\x1a")
    out = MAGIC
    out += section(1, vec(types))
    out += section(2, vec(imports))
    out += section(3, vec([u32(f) for f in funcs]))
    out += section(5, vec(mems))
    out += section(7, vec(exports))
    out += section(10, vec([init]))
    out += section(11, vec(data))
    return out


# ------------------------------------------------------- grown_memory ---
# A memory that is **not exported** and that `init()` grows. Both halves
# matter: `wasm_validate` makes an unexported, unimported memory
# unobservable, so `size_pages/1` reads the record field rather than an
# atomics cell, and a restore that grew through a stale handle writes
# against the pre-grow size.
def grown_memory():
    types = [functype([], []), functype([], [I32])]
    funcs = [0, 1, 1]                       # init, handle, ready
    mems = [b"\x00" + u32(1)]                # min 1 page, no max, NOT exported
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END]
    exports = [export("init", 0x00, 0), export("handle", 0x00, 1),
               export("ready", 0x00, 2)]
    init = body([],
                b"\x41" + i32(1) + b"\x40\x00" + b"\x1a" +      # memory.grow 1, drop
                b"\x41" + i32(65536) + b"\x41" + i32(4242) +
                b"\x36\x02\x00" +                               # i32.store
                b"\x41" + i32(1) + b"\x24" + u32(0))
    handle = body([], b"\x41" + i32(65536) + b"\x28\x02\x00")   # i32.load
    ready = body([], b"\x23" + u32(0))
    return module(types=types, funcs=funcs, mems=mems, globals_=globals_,
                  exports=exports, code=[init, handle, ready])

# ----------------------------------------------------- exported_global ---
# A mutable global the module **exports**, which `wasm_instance` makes a
# `wasm_global` cell rather than a value. Capturing the tuple raw captures
# the source instance's cell, so two restores share one global and the
# initialisation instance's destruction takes the cell with it.
def exported_global():
    types = [functype([], []), functype([], [I32])]
    funcs = [0, 1, 1]
    mems = [b"\x00" + u32(1)]
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END,   # $counter, exported
                bytes([I32, 0x01]) + b"\x41" + i32(0) + END]   # $ready
    exports = [export("memory", 0x02, 0),
               export("counter", 0x03, 0),
               export("init", 0x00, 0), export("handle", 0x00, 1),
               export("ready", 0x00, 2)]
    init = body([], b"\x41" + i32(7) + b"\x24" + u32(0) +
                    b"\x41" + i32(1) + b"\x24" + u32(1))
    # Answers the value it found, then bumps it. A second request restored
    # from the same image must answer 7 again.
    handle = body([], b"\x23" + u32(0) +
                      b"\x23" + u32(0) + b"\x41" + i32(1) + b"\x6a" +
                      b"\x24" + u32(0))
    ready = body([], b"\x23" + u32(1))
    return module(types=types, funcs=funcs, mems=mems, globals_=globals_,
                  exports=exports, code=[init, handle, ready])

# ------------------------------------------------------- grown_table ---
# A table `init()` grows past its declared minimum. Memories grow to fit on
# restore and tables did not, so a guest that grows one captures fine and
# fails to restore.
def grown_table():
    types = [functype([], []), functype([], [I32])]
    funcs = [1, 0, 1, 1]                    # answer, init, handle, ready
    tables = [b"\x70\x00" + u32(1)]         # funcref, min 1, no max
    mems = [b"\x00" + u32(1)]
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END]
    exports = [export("memory", 0x02, 0),
               export("init", 0x00, 1), export("handle", 0x00, 2),
               export("ready", 0x00, 3)]
    elems = [b"\x03\x00" + vec([u32(0)])]   # declarative, so ref.func 0 is legal
    answer = body([], b"\x41" + i32(99))
    init = body([],
                b"\xd2" + u32(0) + b"\x41" + i32(1) +
                b"\xfc" + u32(15) + u32(0) + b"\x1a" +         # table.grow 0, drop
                b"\x41" + i32(1) + b"\xd2" + u32(0) + b"\x26" + u32(0) +
                b"\x41" + i32(1) + b"\x24" + u32(0))
    handle = body([], b"\x41" + i32(1) + b"\x11" + u32(1) + b"\x00")
    ready = body([], b"\x23" + u32(0))
    return module(types=types, funcs=funcs, tables=tables, mems=mems,
                  globals_=globals_, exports=exports, elems=elems,
                  code=[answer, init, handle, ready])

# ------------------------------------------------------- zeroed_data ---
# A module whose active data segment fills memory with a pattern, and whose
# `init()` zeroes part of it. A fresh instance is **not** zero: `new/3` runs
# the data segments first. So a restore that skipped the zero regions would
# leave the segment's byte where `init()` put a zero, which is a wrong
# answer rather than a crash.
def zeroed_data():
    types = [functype([], []), functype([], [I32])]
    funcs = [0, 1, 1]
    mems = [b"\x00" + u32(1)]
    globals_ = [bytes([I32, 0x01]) + b"\x41" + i32(0) + END]
    exports = [export("memory", 0x02, 0),
               export("init", 0x00, 0), export("handle", 0x00, 1),
               export("ready", 0x00, 2)]
    datas = [active_data(0, b"\xAA" * 256)]
    init = body([],
                b"\x41" + i32(0) + b"\x41" + i32(0) + b"\x3a\x00\x00" +
                b"\x41" + i32(128) + b"\x41" + i32(0x99) + b"\x3a\x00\x00" +
                b"\x41" + i32(1) + b"\x24" + u32(0))
    # byte 0 | byte 128 << 8 | byte 255 << 16
    handle = body([],
                  b"\x41" + i32(0) + b"\x2d\x00\x00" +
                  b"\x41" + i32(128) + b"\x2d\x00\x00" +
                  b"\x41" + i32(8) + b"\x74" + b"\x72" +
                  b"\x41" + i32(255) + b"\x2d\x00\x00" +
                  b"\x41" + i32(16) + b"\x74" + b"\x72")
    ready = body([], b"\x23" + u32(0))
    return module(types=types, funcs=funcs, mems=mems, globals_=globals_,
                  exports=exports, code=[init, handle, ready], datas=datas)

# --------------------------------------------------- holds_host_value ---
# A mutable `externref` global that `init()` fills from a host import. An
# external reference is whatever the embedder handed over -- a pid, a port, a
# closure -- and none of those mean anything outside this node, so the capture
# has to refuse. The refusal it replaced looked for `{externref, _}`, which
# nothing constructs.
EXTERNREF = 0x6F

def holds_host_value():
    types = [functype([], [EXTERNREF]), functype([], []), functype([], [I32])]
    imports = [name("env") + name("get") + b"\x00" + u32(0)]
    funcs = [1, 2]                          # init, ready
    mems = [b"\x00" + u32(1)]
    globals_ = [bytes([EXTERNREF, 0x01]) + b"\xd0" + bytes([EXTERNREF]) + END,
                bytes([I32, 0x01]) + b"\x41" + i32(0) + END]
    exports = [export("memory", 0x02, 0),
               export("init", 0x00, 1), export("ready", 0x00, 2)]
    init = body([], b"\x10" + u32(0) + b"\x24" + u32(0) +
                    b"\x41" + i32(1) + b"\x24" + u32(1))
    ready = body([], b"\x23" + u32(1))
    return module(types=types, imports=imports, funcs=funcs, mems=mems,
                  globals_=globals_, exports=exports, code=[init, ready])

if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else "test/fixtures/snapshot"
    os.makedirs(dest, exist_ok=True)
    for nm, fn in [("reactor", reactor), ("started", started),
                   ("imports_memory", imports_memory),
                   ("holds_external", holds_external),
                   ("wasi_opener", wasi_opener),
                   ("grown_memory", grown_memory),
                   ("exported_global", exported_global),
                   ("grown_table", grown_table),
                   ("zeroed_data", zeroed_data),
                   ("holds_host_value", holds_host_value)]:
        path = os.path.join(dest, nm + ".wasm")
        data = fn()
        with open(path, "wb") as f:
            f.write(data)
        print(f"{path}  {len(data)} bytes")
