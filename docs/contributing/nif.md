# The file NIF

The optional file NIF in `c_src/wasi_file_nif.c` is the only C in the
project. It closes the time-of-check-to-time-of-use window in WASI path
resolution described in [WASI](../wasi.md), and it is where a memory error
would be invisible from Erlang. This page is for you if you are changing
`c_src/`: it says how to run the NIF under a sanitizer and what a sanitizer
can and cannot find. The checks every change passes are in
[Contributing](../../CONTRIBUTING.md).

## Run the NIF under a sanitizer

```sh
./scripts/sanitize.sh                      # the NIF suite
./scripts/sanitize.sh test/wasi_SUITE      # any suite
```

That builds the NIF with AddressSanitizer inside a Linux container and runs the
suite against it. A sanitizer has to be in the process before anything it
watches, and Linux is where you can arrange that without rebuilding the
emulator: `LD_PRELOAD` survives the exec from `erl` to the emulator there.

To do it by hand, or in an image of your own:

```sh
export WASM_NIF_SANITIZE=address   # kept set: `rebar3 ct` recompiles
rebar3 compile
LD_PRELOAD=$(gcc -print-file-name=libasan.so) \
  ASAN_OPTIONS=detect_stack_use_after_return=1:detect_leaks=0:abort_on_error=1 \
  rebar3 ct --suite=test/wasi_nif_SUITE
```

## Run the check build

A pointer left into a stack frame that has returned is the one defect the
sanitizer above cannot see in this NIF. Such a name is only read by the
system call it is passed to, and a sanitizer does not watch system calls.
Whether the stale bytes still read right depends on the compiler and on what
ran in between, so the plain suites pass on one machine and fail on another.

The check build makes it fail every time. It overwrites the stack a path
resolution has just returned from, before the name is used. It is built
unoptimised and not inlined, so each function keeps its own frame:

```sh
WASM_NIF_CFLAGS="-DWASM_NIF_STACK_CHECK -O0 -fno-inline" rebar3 compile
rebar3 ct --suite=test/wasi_nif_SUITE,test/wasi_SUITE
```

CI runs both, in the job "NIF checks".

## What each sanitizer will and will not find

**AddressSanitizer will not find every defect this NIF can have.** It watches
memory. Closing a descriptor while another thread reads it is not a memory
error: the read succeeds, against whatever file the kernel handed that number
to next. ThreadSanitizer is what sees that one, because the race is on the
descriptor field itself.

**ThreadSanitizer cannot be preloaded.** Unlike AddressSanitizer it needs the
whole program instrumented, and preloading it into a stock emulator segfaults
it outright rather than reporting anything. You need an emulator built with
it. CI's "NIF under ThreadSanitizer" job (`.github/workflows/tsan.yml`) does
the following on Linux, weekly and whenever the NIF changes, and you can run
the same steps by hand.

Build only the emulator, at the OTP version you run:

```sh
git clone --depth 1 --branch OTP-29.1.2 https://github.com/erlang/otp
cd otp && export ERL_TOP=$PWD
./otp_build configure CFLAGS="-fsanitize=thread -fPIE -O1 -g" \
  LDFLAGS="-fsanitize=thread"
make -C erts/lib_src opt
make -C erts/emulator opt
```

Copy `bin/<arch>/beam.smp` over the `beam.smp` of an installed OTP of the
same version. Then build the NIF instrumented and run the file suites:

```sh
sudo sysctl -w vm.mmap_rnd_bits=28
export ERL_FLAGS="+Mea min"
export TSAN_OPTIONS="detect_deadlocks=0 halt_on_error=0 exitcode=0 log_path=/tmp/tsan/report"
WASM_NIF_SANITIZE=thread rebar3 ct --suite=test/wasi_nif_SUITE,test/wasi_SUITE
grep -l wasi_file_nif /tmp/tsan/report*
```

Each setting is there for a reason:

- `vm.mmap_rnd_bits=28`: with the kernel's default address randomisation,
  ThreadSanitizer cannot map its shadow memory.
- `detect_deadlocks=0`: the lock-order detector tracks at most 64 held
  locks. ERTS holds more, and the detector's failed check hangs the emulator.
- `+Mea min`: ERTS's own allocators hand a freed block to another thread
  with atomics ThreadSanitizer cannot see. Without this, a new file handle in
  a recycled block is reported as racing the old handle's destructor.

Expect noise even then. ERTS's atomics are inline assembly, so its deliberate
lock-free code is reported by the thousand. Read only the reports with a
`wasi_file_nif` frame. That is all the CI job fails on.

**Neither of them replaces the test.** `wasi_nif_SUITE` reproduces the
close-against-read race with no sanitizer at all, by asserting that no read
ever returns a byte belonging to another file. That is the cheaper check, it is
wired into `rebar3 ct`, and it is the one that caught the defect. Sanitizers
are for what a test cannot phrase.

## Short notes

- On macOS none of this works natively. `DYLD_INSERT_LIBRARIES` is stripped
  when the `erl` launcher execs the emulator, so an instrumented library gets
  you `Interceptors are not working`: the runtime arrived through `dlopen`,
  after the fact. Use the container.
- Leak detection is off in the script on purpose. The emulator holds
  allocations for its whole life by design, so it reports pages of them and
  none of them are the NIF.
- `WASM_SANITIZE_IMAGE` picks a different base image if you need a particular
  OTP version.

## Read this next

[Testing](testing.md), for the suites and fixtures, or [WASI](../wasi.md) for
what the NIF protects.
