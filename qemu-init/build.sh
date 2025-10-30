#!/usr/bin/env bash
# Compile init.zig to static Linux binary

set -euo pipefail

zig build-exe \
    -target x86_64-linux-musl \
    -O ReleaseSafe \
    -fstrip \
    -fsingle-threaded \
    init.zig

echo "Built: init ($(ls -lh init | awk '{print $5}'))"
