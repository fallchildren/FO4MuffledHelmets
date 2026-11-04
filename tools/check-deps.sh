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
need cmake      "cmake"
need g++        "gcc (C++23 capable, e.g. GCC 13+)"
need python3    "python"
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

echo "libraries (for Caprica):"
if command -v pkg-config >/dev/null 2>&1; then
    for lib in fmt pugixml; do
        if pkg-config --exists "$lib"; then echo "  ok       $lib"
        else echo "  MISSING  $lib       dev package for $lib"; missing=1; fi
    done
else
    echo "  MISSING  pkg-config"; missing=1
fi
if echo '#include <boost/program_options.hpp>
#include <boost/container/flat_map.hpp>' | g++ -x c++ -fsyntax-only - >/dev/null 2>&1; then
    echo "  ok       boost (program_options, container, filesystem headers)"
else
    echo "  MISSING  boost      boost dev package (>= 1.7x)"; missing=1
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
