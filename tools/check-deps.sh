#!/usr/bin/env bash
# Verify the host tools/libraries the build needs. Nothing is installed here.
set -u
missing=0
need() {   # need <command> <hint>
    if command -v "$1" >/dev/null 2>&1; then
        printf '  ok       %s\n' "$1"
    else
        printf '  MISSING  %-10s %s\n' "$1" "$2"
        missing=1
    fi
}

echo "tools:"
need git        "git"
need make       "make"
need python3    "python"
need curl       "curl (Jezebel release download)"
need cargo      "rust toolchain (rustup default stable)"
need rustc      "rust toolchain (rustup default stable)"
need clang-cl   "clang"
need llvm-lib   "llvm"
if command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1; then
    echo "  ok       7z"
else
    echo "  MISSING  7z        7zip / p7zip (provides 7z, 7zz or 7za)"
    missing=1
fi


echo "linker for the plugin:"
if command -v rustc >/dev/null 2>&1; then
    lld="$(rustc --print target-libdir 2>/dev/null)/../bin/rust-lld"
    if [ -x "$lld" ]; then echo "  ok       rust-lld ($lld)"
    else echo "  MISSING  rust-lld   use a rustup-installed toolchain (it ships rust-lld)"; missing=1; fi
fi

if [ "$missing" -ne 0 ]; then
    echo
    echo "Install the missing items (see README.md, 'Prerequisites') and run make again."
    exit 1
fi
echo "all prerequisites found"
