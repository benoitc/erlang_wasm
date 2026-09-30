#!/usr/bin/env bash
# Build test/fixtures/lang/py_reactor.wasm and its standard library:
# CPython as an init()/handle() reactor, which is the shape initialized
# runtime snapshots need.
#
# Upstream builds `python.wasm` as a WASI command. By the time its `_start`
# returns, `Py_Finalize` has run and the interpreter is gone, so there is no
# point in its life worth capturing. This links CPython's own static library
# against test/fixtures/lang/python_reactor/worker_reactor.c instead, with
# `-mexec-model=reactor`, and reuses the link line the project's own Makefile
# computes rather than reconstructing it: that line names about four hundred
# objects and five static libraries, and a hand-written copy would rot.
#
# It needs a WASI SDK, cmake's neighbours (make, a host compiler), binaryen's
# `wasm-opt` and about twenty minutes, because it builds a host CPython first
# to cross-compile with.
#
#   WASI_SDK=/path/to/wasi-sdk-34.0-arm64-macos scripts/build-python-reactor.sh
#
# Two steps after the link shape what ships:
#
# - `wasm-opt --strip-debug` drops the DWARF: 23 of the 31 MB the link
#   produces, with no change in request speed. No `-O` level is applied,
#   because every one measured made this runtime slower.
# - The standard library ships precompiled. It used to ship as 554 `.py` files
#   and no `.pyc`, so every module a request imported that was not already in
#   the image was compiled from source in that request, interpreted. The
#   build's own host interpreter compiles it instead, which is the same
#   version by construction.
#
# There is no `.sha256` beside the output, and that is deliberate: the artifact
# embeds its own build directory, so a checksum would pin this machine rather
# than the recipe. `test/fixtures/lang/PYTHON.md` records the hash this box
# produced as provenance, not as a gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/lang"
SRC="$DEST/python_reactor/worker_reactor.c"

TAG="${CPYTHON_TAG:-v3.14.7}"
XY="${CPYTHON_XY:-3.14}"
WASI_SDK="${WASI_SDK:-$HOME/.local/opt/wasi-sdk-34.0-arm64-macos}"

[ -x "$WASI_SDK/bin/clang" ] || {
    echo "no WASI SDK at $WASI_SDK; set WASI_SDK, or install wasi-sdk-34" >&2
    echo "  https://github.com/WebAssembly/wasi-sdk/releases/tag/wasi-sdk-34" >&2
    exit 1
}
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
# Required rather than skipped with a warning: an unstripped artifact is four
# times the size and still works, so a warning would scroll past and leave a
# fixture that differs from the one PYTHON.md records without anyone noticing.
WASM_OPT="${WASM_OPT:-$(command -v wasm-opt || true)}"
[ -n "$WASM_OPT" ] && [ -x "$WASM_OPT" ] || {
    echo "wasm-opt not found; install binaryen or set WASM_OPT" >&2
    echo "  https://github.com/WebAssembly/binaryen/releases" >&2
    exit 1
}

# A fixed path rather than a temporary one, because the artifact embeds it: two
# builds from the same checkout then agree, which is the most a build that
# records its own directory can offer.
WORK="$ROOT/_build/python-reactor"
mkdir -p "$WORK"

if [ ! -d "$WORK/cpython" ]; then
    echo "cloning CPython $TAG"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" \
        https://github.com/python/cpython.git "$WORK/cpython"
fi

B="$WORK/cpython/cross-build/wasm32-wasip1"
if [ ! -f "$B/libpython$XY.a" ]; then
    # CPython's own driver: it builds a host interpreter first, because
    # cross-compiling needs one to run the build steps written in Python.
    echo "building CPython for wasm32-wasip1 (this takes a while)"
    (cd "$WORK/cpython" && WASI_SDK_PATH="$WASI_SDK" \
        python3 Tools/wasm/wasi build >"$WORK/build.log" 2>&1) || {
        echo "CPython build failed; see $WORK/build.log" >&2
        exit 1
    }
fi

echo "compiling the reactor shim"
(cd "$B" && "$WASI_SDK/bin/clang" -c -O2 -Wall \
    -I. -IInclude -I../../Include -o worker_reactor.o "$SRC")

# The Makefile knows every object and library that goes into `python.wasm`.
# Ask it, swap the command's entry point for ours, and add the reactor model.
# python-link-line.sh fails rather than print anything that is not the link
# line, and the entry-point swap is checked, because a line that kept
# Programs/python.o would link CPython's own `main` under the reactor model
# and produce a broken artifact without a word.
echo "linking"
LINK="$("$ROOT/scripts/python-link-line.sh" "$B")"
LINK="$(printf '%s\n' "$LINK" \
    | sed 's| Programs/python.o | worker_reactor.o |' \
    | sed 's|-o python.wasm|-mexec-model=reactor -o py_reactor.wasm|')"
case "$LINK" in
    *worker_reactor.o*) ;;
    *) echo "the link line does not name Programs/python.o: $LINK" >&2
       exit 1 ;;
esac
(cd "$B" && sh -c "$LINK")

# The features are named rather than detected: `--mvp-features` first, then
# exactly the nine the link emits, so a binaryen whose defaults change cannot
# add one the runtime does not implement.
echo "stripping debug info"
"$WASM_OPT" --strip-debug --mvp-features \
    --enable-bulk-memory --enable-bulk-memory-opt \
    --enable-call-indirect-overlong --enable-extended-const \
    --enable-multivalue --enable-mutable-globals \
    --enable-nontrapping-float-to-int --enable-reference-types \
    --enable-sign-ext \
    -o "$DEST/py_reactor.wasm" "$B/py_reactor.wasm"

# The standard library, beside it, for the read-only mount the adapter
# declares. Trimmed to what a worker can reach: the test suites alone are most
# of the 259 MB an install produces, and nothing here can open a GUI or a
# package index.
echo "staging the standard library"
PYLIB="$DEST/py_reactor_lib"
rm -rf "$PYLIB"
mkdir -p "$PYLIB"
(cd "$B" && make install DESTDIR="$WORK/install" >/dev/null 2>&1) || true
cp -R "$WORK/install/usr/local/lib/python$XY" "$PYLIB/"
(cd "$PYLIB/python$XY" && rm -rf test idlelib tkinter turtledemo pydoc_data \
     ensurepip site-packages "config-$XY-wasm32-wasi" || true)
find "$PYLIB" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PYLIB" -name tests -type d -prune -exec rm -rf {} + 2>/dev/null || true

# Precompile with the interpreter the cross-build ran on, not whatever
# `python3` is on the path: a `.pyc` from another version is ignored by magic
# number and the import falls back to compiling the source, silently.
#
# - `-o 0`, the plain `.pyc`: the shim's isolated configuration leaves
#   `optimization_level` at 0, which never looks for an `opt-1` file.
# - `unchecked-hash`: the import neither stats nor reads the source, and the
#   file carries no mtime. A timestamp `.pyc` would be invalidated by any copy
#   that does not keep mtimes, and fall back to source without a word; the
#   mount is read-only, so the source cannot change under a hash anyway.
# - `-s`/`-p`: the embedded file names are the guest's `/lib/...` paths rather
#   than this checkout's, so two checkouts produce the same bytes.
echo "compiling the standard library"
HOSTPY="$(ls -d "$WORK"/cpython/cross-build/*/python.exe 2>/dev/null \
    | grep -v wasm32 | head -n 1 || true)"
[ -n "$HOSTPY" ] && [ -x "$HOSTPY" ] || {
    echo "no host python.exe under $WORK/cpython/cross-build" >&2
    exit 1
}
"$HOSTPY" -I -m compileall -q -j0 -o 0 \
    --invalidation-mode unchecked-hash -s "$PYLIB" -p /lib "$PYLIB" || {
    echo "compileall failed on $PYLIB" >&2
    exit 1
}

echo "built $(wc -c < "$DEST/py_reactor.wasm") bytes to $DEST/py_reactor.wasm"
echo "standard library in $PYLIB ($(du -sh "$PYLIB" | cut -f1))"
if command -v shasum >/dev/null 2>&1; then
    (cd "$DEST" && shasum -a 256 py_reactor.wasm)
else
    (cd "$DEST" && sha256sum py_reactor.wasm)
fi
