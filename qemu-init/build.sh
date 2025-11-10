#!/usr/bin/env bash
# Compile Zig helpers used by the QEMU initramfs.

set -euo pipefail

zig_opts=(
    -target x86_64-linux-musl
    -O ReleaseSafe
    -fstrip
    -fsingle-threaded
)

build() {
    local src=$1
    local out=$2
    zig build-exe "${zig_opts[@]}" "$src" -femit-bin="$out"
    local size
    size=$(ls -lh "$out" | awk '{print $5}')
    echo "Built: $out ($size)"
}

build init.zig init
build test_child.zig test_child
build test_input.zig test-input
