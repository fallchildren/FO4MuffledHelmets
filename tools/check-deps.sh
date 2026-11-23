#!/usr/bin/env bash
# Verify the host tools needed for packaging and PSL compilation.
# Native compiler/linker checks live in check-native-deps.sh.
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
if command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1; then
    echo "  ok       7z"
else
    echo "  MISSING  7z        7zip / p7zip (provides 7z, 7zz or 7za)"
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    echo
    echo "Install the missing items (see README.md, 'Prerequisites') and run make again."
    exit 1
fi
echo "all prerequisites found"
