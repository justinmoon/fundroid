#!/usr/bin/env bash
set -euo pipefail

# CI script for webos project
# Runs inside the Nix development environment

echo "Running CI checks..."

# Run clippy on all projects for both architectures
echo "Running clippy checks..."
cargo clippy --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android -- -D warnings
cargo clippy --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android -- -D warnings
cargo clippy --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android -- -D warnings
cargo clippy --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android -- -D warnings

# Build tests for all projects for both architectures
# Note: We use --no-run because these are Android binaries that can't execute on macOS
# Tests will run on the actual device/emulator
echo "Building tests..."
cargo test --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --no-run
cargo test --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --no-run
cargo test --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --no-run
cargo test --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --no-run

# Build release binaries for all projects for both architectures
echo "Building release binaries..."
cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release
cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release
cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release
cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release

echo "CI passed!"
