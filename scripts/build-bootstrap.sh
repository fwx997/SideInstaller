#!/bin/bash
# Cross-build the static Linux ARM64 bootstrap on the existing macOS runner.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$1"
BUILD_ROOT="${RUNNER_TEMP:-$ROOT/build}/siboot-cross"
mkdir -p "$BUILD_ROOT/CertificateReuseBuild"
python3 -m venv "$BUILD_ROOT/venv"
"$BUILD_ROOT/venv/bin/python" -m pip install --disable-pip-version-check 'cargo-zigbuild==0.20.4' 'ziglang==0.13.0'
export PATH="$BUILD_ROOT/venv/bin:$PATH"
rustup target add aarch64-unknown-linux-musl
export CARGO_TARGET_DIR="$ROOT/bootstrap/target"
export RUSTFLAGS="-C target-feature=+crt-static -C relocation-model=static"
cargo zigbuild --manifest-path "$ROOT/bootstrap/Cargo.toml" --release --locked --target aarch64-unknown-linux-musl
cp "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/siboot" "$BUILD_ROOT/CertificateReuseBuild/siboot-aarch64"
file "$BUILD_ROOT/CertificateReuseBuild/siboot-aarch64"
git -C "$ROOT" rev-parse HEAD > "$BUILD_ROOT/CertificateReuseBuild/source-commit.txt"
cp "$ROOT/bootstrap/Cargo.lock" "$BUILD_ROOT/CertificateReuseBuild/bootstrap-Cargo.lock"
(cd "$BUILD_ROOT" && shasum -a 256 CertificateReuseBuild/siboot-aarch64 > CertificateReuseBuild/SHA256SUMS)
(cd "$BUILD_ROOT" && zip -q "$OUTPUT" CertificateReuseBuild/*)
echo "==> Application and static bootstrap collected in $OUTPUT"
