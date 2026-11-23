#!/usr/bin/env bash
# Verify the cross-compiler/linker used by native/.
set -u
missing=0
need() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '  ok       %s\n' "$1"
    else
        printf '  MISSING  %-10s %s\n' "$1" "$2"
        missing=1
    fi
}

need cargo      "rust toolchain (rustup default stable)"
need rustc      "rust toolchain (rustup default stable)"
need clang-cl   "clang"
need llvm-lib   "llvm"

if command -v rustc >/dev/null 2>&1; then
    lld="$(rustc --print target-libdir 2>/dev/null)/../bin/rust-lld"
    if [ -x "$lld" ]; then
        echo "  ok       rust-lld ($lld)"
    else
        echo "  MISSING  rust-lld   use a rustup-installed toolchain (it ships rust-lld)"
        missing=1
    fi
fi

if [ "$missing" -ne 0 ]; then
    echo
    echo "Install the missing items (see README.md, 'Prerequisites') and run make again."
    exit 1
fi
echo "all native prerequisites found"
