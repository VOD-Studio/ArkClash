#!/usr/bin/env bash
# Cross-compiles core/ (mihomo) into entry/libs/arm64-v8a/libclash.so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OHOS_SDK="${OHOS_SDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"
LLVM="$OHOS_SDK/native/llvm/bin"
OUT="$ROOT/entry/libs/arm64-v8a"

if [[ ! -x "$LLVM/aarch64-unknown-linux-ohos-clang" ]]; then
  echo "OHOS NDK not found at $OHOS_SDK; set OHOS_SDK" >&2
  exit 1
fi

# 补丁按 .go-version 里的 Go 版本制作，版本不同时补丁可能打不上。
WANT_GO="$(cat "$ROOT/.go-version")"
if [[ "$(go env GOVERSION)" != "go$WANT_GO" ]]; then
  echo "警告：本机是 $(go env GOVERSION)，项目固定 go$WANT_GO（.go-version）" >&2
fi

# Stock Go cannot produce a c-shared library that musl can dlopen (golang/go#54805).
# Build with a private copy of the local Go toolchain carrying go-ohos.patch.
GO_VERSION="$(go env GOVERSION)"
TOOLCHAIN="$ROOT/.toolchain/$GO_VERSION-ohos"
PATCH="$ROOT/scripts/go-ohos.patch"
STAMP="$TOOLCHAIN/.arkclash-patch"
if [[ ! -f "$STAMP" ]] || ! cmp -s "$PATCH" "$STAMP"; then
  echo "preparing patched $GO_VERSION in $TOOLCHAIN"
  rm -rf "$TOOLCHAIN" "$TOOLCHAIN.tmp"
  mkdir -p "$ROOT/.toolchain"
  cp -R "$(go env GOROOT)" "$TOOLCHAIN.tmp"
  chmod -R u+w "$TOOLCHAIN.tmp"
  patch -s -p1 -d "$TOOLCHAIN.tmp" < "$PATCH"
  cp "$PATCH" "$TOOLCHAIN.tmp/.arkclash-patch"
  mv "$TOOLCHAIN.tmp" "$TOOLCHAIN"
fi
GO="$TOOLCHAIN/bin/go"
export GOROOT="$TOOLCHAIN" GOTOOLCHAIN=local

cd "$ROOT/core"
MIHOMO_VERSION="$("$GO" list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
mkdir -p "$OUT"

# 需要打补丁的依赖：复制到 .toolchain 打补丁，再用临时 go.mod（-modfile）
# replace 过去，core/go.mod 保持原样。
# gvisor-fdbased.patch：SELinux 不允许对 TUN fd 做 fstat，见补丁里的注释。
PATCHED_DIR="$ROOT/.toolchain/patched"
rm -rf "$PATCHED_DIR"
mkdir -p "$PATCHED_DIR"
GVISOR_DIR="$("$GO" list -m -f '{{.Dir}}' github.com/metacubex/gvisor)"
cp -R "$GVISOR_DIR" "$PATCHED_DIR/gvisor"
chmod -R u+w "$PATCHED_DIR/gvisor"
patch -s -p1 -d "$PATCHED_DIR/gvisor" < "$ROOT/scripts/gvisor-fdbased.patch"
cp go.mod "$PATCHED_DIR/go.mod"
cp go.sum "$PATCHED_DIR/go.sum"
echo "replace github.com/metacubex/gvisor => $PATCHED_DIR/gvisor" >> "$PATCHED_DIR/go.mod"

# HarmonyOS uses musl, so this is a GOOS=linux build linked by the OHOS clang.
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC="$LLVM/aarch64-unknown-linux-ohos-clang" \
  CXX="$LLVM/aarch64-unknown-linux-ohos-clang++" \
  "$GO" build -buildmode=c-shared -tags with_gvisor -trimpath -modfile "$PATCHED_DIR/go.mod" \
    -ldflags "-s -w -extldflags=-Wl,-soname,libclash.so -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
    -o "$OUT/libclash.so" .

# The C++ bridge uses the hand-written arkclash.h instead.
rm -f "$OUT/libclash.h"

# musl rejects initial-exec TLS relocations in dlopen'ed libraries.
# 允许 TLSDESC（general-dynamic），只拦 initial-exec 用的 TPREL。
if "$LLVM/llvm-readelf" -r "$OUT/libclash.so" | grep -q "R_AARCH64_TLS_TPREL"; then
  echo "libclash.so still has TLS relocations; is go-ohos.patch applied?" >&2
  exit 1
fi
echo "built $OUT/libclash.so (mihomo $MIHOMO_VERSION)"
