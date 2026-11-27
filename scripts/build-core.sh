#!/usr/bin/env bash
# 交叉编译 core/（mihomo）到所选 ABI 的 libclash.so。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
LLVM="$OHOS_SDK/native/llvm/bin"
ABI="${ABI:-arm64-v8a}"
case "$ABI" in
  arm64-v8a)
    ARCH=arm64
    TRIPLE=aarch64-unknown-linux-ohos
    PATCH="$ROOT/scripts/go-ohos.patch"
    TLS_RELOC=R_AARCH64_TLS_TPREL
    ;;
  x86_64)
    ARCH=amd64
    TRIPLE=x86_64-unknown-linux-ohos
    PATCH="$ROOT/scripts/go-ohos-amd64.patch"
    TLS_RELOC='R_X86_64_(TPOFF|GOTTPOFF)'
    ;;
  *) echo "不支持的 ABI：${ABI}（仅支持 arm64-v8a、x86_64）" >&2; exit 2 ;;
esac
OUT="$ROOT/entry/libs/$ABI"

if [[ ! -x "$LLVM/$TRIPLE-clang" ]]; then
  echo "OHOS NDK not found at $OHOS_SDK; set OHOS_SDK" >&2
  exit 1
fi

# 编译器补丁绑定项目版本，不能借用 PATH 上另一版 Go 的编译器。
WANT_GO="$(cat "$ROOT/.go-version")"
export GOTOOLCHAIN="go$WANT_GO"

# Stock Go cannot produce a c-shared library that musl can dlopen (golang/go#54805).
# 按 ABI 应用补丁，保留系统 Go 不变。
GO_VERSION="$(go env GOVERSION)"
TOOLCHAIN="$ROOT/.toolchain/$GO_VERSION-ohos-$ABI"
STAMP="$TOOLCHAIN/.arkclash-patch"
if [[ ! -f "$STAMP" ]] || ! cmp -s "$PATCH" "$STAMP"; then
  echo "preparing patched $GO_VERSION in $TOOLCHAIN"
  rm -rf "$TOOLCHAIN" "$TOOLCHAIN.tmp"
  mkdir -p "$ROOT/.toolchain"
  cp -R "$(go env GOROOT)" "$TOOLCHAIN.tmp"
  chmod -R u+w "$TOOLCHAIN.tmp"
  patch -s -p1 -d "$TOOLCHAIN.tmp" < "$PATCH"
  if [[ "$ABI" == x86_64 ]]; then
    # x86 的 TLS 指令由汇编器生成，必须同时重建共享该后端的三个工具。
    GOROOT="$TOOLCHAIN.tmp" GOTOOLCHAIN=local CGO_ENABLED=0 \
      GOOS="$(go env GOHOSTOS)" GOARCH="$(go env GOHOSTARCH)" \
      "$TOOLCHAIN.tmp/bin/go" install cmd/asm cmd/compile cmd/link
  fi
  cp "$PATCH" "$TOOLCHAIN.tmp/.arkclash-patch"
  mv "$TOOLCHAIN.tmp" "$TOOLCHAIN"
fi
GO="$TOOLCHAIN/bin/go"
export GOROOT="$TOOLCHAIN" GOTOOLCHAIN=local PATH="$TOOLCHAIN/bin:$PATH"

cd "$ROOT/core"
MIHOMO_VERSION="$("$GO" list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
mkdir -p "$OUT"

# 需要打补丁的依赖：复制到 .toolchain 打补丁，再用临时 go.mod（-modfile）
# replace 过去，core/go.mod 保持原样。
PATCHED_DIR="$ROOT/.toolchain/patched-$ABI"
bash "$ROOT/scripts/prepare-core-modfile.sh" "$PATCHED_DIR"

quickjs_dir="$(bash "$ROOT/scripts/prepare-quickjs.sh")"
export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -I \"$quickjs_dir\""

# HarmonyOS uses musl, so this is a GOOS=linux build linked by the OHOS clang.
CGO_ENABLED=1 GOOS=linux GOARCH="$ARCH" \
  CC="$LLVM/$TRIPLE-clang" \
  CXX="$LLVM/$TRIPLE-clang++" \
  "$GO" build -buildmode=c-shared -tags with_gvisor -trimpath -modfile "$PATCHED_DIR/go.mod" \
    -ldflags "-s -w -extldflags=-Wl,-soname,libclash.so -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
    -o "$OUT/libclash.so" .

# 备份库在界面进程延迟加载，不链接 mihomo。
CGO_ENABLED=1 GOOS=linux GOARCH="$ARCH" CC="$LLVM/$TRIPLE-clang" \
  "$GO" build -buildmode=c-shared -trimpath \
    -ldflags "-s -w -extldflags=-Wl,-soname,libarkstore_impl.so" \
    -o "$OUT/libarkstore_impl.so" ./backupstore
rm -f "$OUT/libarkstore_impl.h"

# The C++ bridge uses the hand-written arkclash.h instead.
rm -f "$OUT/libclash.h"

# musl rejects initial-exec TLS relocations in dlopen'ed libraries.
# 允许 TLSDESC，禁止需要预留静态 TLS 的 TPREL/TPOFF。
# 先把输出完整读进变量再查：直接接管道时 grep -q 命中就退出，readelf 写不进去而失败，
# pipefail 下整条管道算失败，if 反而放行。
RELOCS="$("$LLVM/llvm-readelf" -r "$OUT/libclash.so")"
if grep -Eq "$TLS_RELOC" <<<"$RELOCS"; then
  echo "libclash.so still has initial-exec TLS relocations; is $PATCH applied?" >&2
  exit 1
fi
RELOCS="$("$LLVM/llvm-readelf" -r "$OUT/libarkstore_impl.so")"
if grep -Eq "$TLS_RELOC" <<<"$RELOCS"; then
  echo "libarkstore_impl.so uses initial-exec TLS" >&2
  exit 1
fi
echo "built $OUT/libclash.so (mihomo $MIHOMO_VERSION) and libarkstore_impl.so"
