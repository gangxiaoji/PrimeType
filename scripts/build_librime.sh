#!/usr/bin/env bash
# 从源码编译 librime 1.17.0，安装到 Vendor/librime/dist/，供 PrimeType 链接与打包。
# 关键：BUILD_STATIC=ON —— leveldb/marisa/opencc/yaml-cpp 等依赖以静态库形式
# 链进 librime.1.dylib，这样打出来的 .app 在没有 Homebrew 的干净 Mac 上也能跑。
# 插件（librime-lua / librime-octagram）以独立 dylib 形式装到 dist/lib/rime-plugins/。
# 在本机架构上原生编译（arm64 runner 编 arm64，Intel runner 编 x86_64），不交叉编译。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIME_DIR="${TMPDIR:-/tmp}/librime-build"
RIME_VERSION="1.17.0"

echo "==> Installing librime build dependencies (Homebrew)..."
brew install boost glog capnp lua cmake pkg-config

echo "==> Cloning librime ${RIME_VERSION} (with submodules: plugins + deps)..."
rm -rf "$LIME_DIR"
git clone --recursive --branch "$RIME_VERSION" --depth 1 \
  https://github.com/rime/librime.git "$LIME_DIR"
cd "$LIME_DIR"

echo "==> Building third-party deps from source (static): leveldb, marisa, opencc, yaml-cpp..."
make deps/leveldb deps/marisa-trie deps/opencc deps/yaml-cpp

echo "==> Configuring librime (shared lib, static deps, separate plugin dylibs)..."
cmake -S . -B build \
  -DCMAKE_INSTALL_PREFIX="$LIME_DIR/dist" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC=ON \
  -DBUILD_MERGED_PLUGINS=OFF \
  -DENABLE_EXTERNAL_PLUGINS=ON \
  -DBUILD_TEST=OFF \
  -DBUILD_SAMPLE=OFF

echo "==> Building librime..."
cmake --build build --parallel

echo "==> Installing librime to dist/..."
cmake --install build

echo "==> librime dist contents:"
find "$LIME_DIR/dist" -type f | sort
echo "==> librime dylib linkage (must be system libs only, no /opt/homebrew or /usr/local):"
otool -L "$LIME_DIR/dist/lib/librime.1.17.0.dylib"
if otool -L "$LIME_DIR/dist/lib/librime.1.17.0.dylib" | grep -E "opt/homebrew|/usr/local" ; then
  echo "ERROR: librime dylib links Homebrew libs; the app would fail on clean Macs." >&2
  exit 1
fi
if [ -d "$LIME_DIR/dist/lib/rime-plugins" ]; then
  echo "==> rime-plugins linkage:"
  for p in "$LIME_DIR/dist/lib/rime-plugins"/*.dylib; do
    [ -f "$p" ] || continue
    echo "--- $p"
    otool -L "$p"
  done
fi

echo "==> Copying dist/ to PrimeType Vendor/librime/dist/..."
rm -rf "$ROOT_DIR/Vendor/librime"
mkdir -p "$ROOT_DIR/Vendor/librime"
cp -R "$LIME_DIR/dist" "$ROOT_DIR/Vendor/librime/dist"
echo "==> librime ready at $ROOT_DIR/Vendor/librime/dist"
