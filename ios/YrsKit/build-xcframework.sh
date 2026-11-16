#!/bin/bash
# Builds Yrs.xcframework: the official y-crdt C library (yffi), the same engine and release
# line the Windows client uses through YDotNet 0.7.0 (branch release-v0.26).
# Run on the Mac, in this directory. Needs Rust (brew install rustup; rustup default stable;
# rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin). The result is not committed.
set -euo pipefail

YCRDT_REPO=https://github.com/y-crdt/y-crdt
YCRDT_COMMIT=5238955513138fb10db67fe6547745fc9df557a5   # release v0.26 (yrs/yffi 0.26.0)

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=15.0

here="$(cd "$(dirname "$0")" && pwd)"
work="$here/.build/y-crdt"
out="$here/Yrs.xcframework"

if [[ ! -d "$work/.git" ]]; then
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" remote add origin "$YCRDT_REPO"
fi
git -C "$work" fetch -q --depth 1 origin "$YCRDT_COMMIT"
git -C "$work" checkout -q --detach "$YCRDT_COMMIT"

targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
for t in "${targets[@]}"; do
  (cd "$work" && cargo build --release --locked -p yffi --target "$t")
done

# The header goes into the CYrs source target (committed), not into the framework: two static
# xcframeworks that both ship a module map collide in Xcode.
mkdir -p "$here/Sources/CYrs/include"
cp "$work/tests-ffi/include/libyrs.h" "$here/Sources/CYrs/include/libyrs.h"

rm -rf "$out"
args=()
for t in "${targets[@]}"; do
  args+=(-library "$work/target/$t/release/libyrs.a")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out"
echo "Built $out"
