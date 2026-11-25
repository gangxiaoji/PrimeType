#!/usr/bin/env bash
# 从源码编译 libopus.a（静态库），覆盖 Vendor/opus/lib/libopus.a。
# 仓库自带的 libopus.a 只有 arm64 slice，Intel 构建必须重新编译。
# 在本机架构上原生编译（在 Intel runner 上得到 x86_64 的 .a）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPUS_DIR="${TMPDIR:-/tmp}/opus-build"
OPUS_VERSION="1.5.2"

echo "==> Cloning opus ${OPUS_VERSION}..."
rm -rf "$OPUS_DIR"
git clone --depth 1 --branch "v${OPUS_VERSION}" \
  https://github.com/xiph/opus.git "$OPUS_DIR"
cd "$OPUS_DIR"

echo "==> Configuring opus (static only)..."
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF \
  -DOPUS_BUILD_TESTING=OFF \
  -DOPUS_BUILD_PROGRAMS=OFF

echo "==> Building opus..."
cmake --build build --parallel

echo "==> Installing libopus.a to Vendor/opus/lib/..."
cp -f "$OPUS_DIR/build/libopus.a" "$ROOT_DIR/Vendor/opus/lib/libopus.a"
echo "==> opus ready:"
lipo -info "$ROOT_DIR/Vendor/opus/lib/libopus.a" || true
