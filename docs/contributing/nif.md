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
WASM_NIF_SANITIZE=address rebar3 compile
LD_PRELOAD=$(gcc -print-file-name=libasan.so) \
  ASAN_OPTIONS=detect_leaks=0 rebar3 ct --suite=test/wasi_nif_SUITE
```

## What each sanitizer will and will not find

**AddressSanitizer will not find every defect this NIF can have.** It watches
memory. Closing a descriptor while another thread reads it is not a memory
error: the read succeeds, against whatever file the kernel handed that number
to next. ThreadSanitizer is what sees that one, because the race is on the
descriptor field itself.

**ThreadSanitizer cannot be preloaded.** Unlike AddressSanitizer it needs the
whole program instrumented, and preloading it into a stock emulator segfaults
it outright rather than reporting anything. That means an emulator built with
it:

```sh
git clone --depth 1 https://github.com/erlang/otp && cd otp
export ERL_TOP=$PWD
./otp_build configure CFLAGS="-fsanitize=thread -fPIE" LDFLAGS="-fsanitize=thread"
make
```

Expect noise. ERTS is full of deliberate lock-free code that ThreadSanitizer
reports, so a suppression file comes before the output is worth reading. This
route is described rather than demonstrated: it has not been run here.

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
