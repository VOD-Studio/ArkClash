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

cd "$ROOT/core"
MIHOMO_VERSION="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
mkdir -p "$OUT"

# HarmonyOS uses musl, so this is a GOOS=linux build linked by the OHOS clang.
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC="$LLVM/aarch64-unknown-linux-ohos-clang" \
  CXX="$LLVM/aarch64-unknown-linux-ohos-clang++" \
  go build -buildmode=c-shared -tags with_gvisor -trimpath \
    -ldflags "-s -w -extldflags=-Wl,-soname,libclash.so -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
    -o "$OUT/libclash.so" .

# The C++ bridge uses the hand-written arkclash.h instead.
rm -f "$OUT/libclash.h"
echo "built $OUT/libclash.so (mihomo $MIHOMO_VERSION)"
