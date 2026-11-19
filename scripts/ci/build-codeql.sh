#!/usr/bin/env bash
# 标准 Go 供 CodeQL 跟踪，业务依赖仍使用手机构建的补丁；产物只供分析。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
LLVM="$OHOS_SDK/native/llvm/bin"
if [[ ! -x "$LLVM/aarch64-unknown-linux-ohos-clang" ]]; then
  echo "未找到 OHOS NDK：$OHOS_SDK" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/core"
cp go.mod go.sum "$WORK/"
bash "$ROOT/scripts/prepare-mihomo.sh" "$WORK/mihomo"
go mod download github.com/metacubex/gvisor
GVISOR_DIR="$(go list -m -f '{{.Dir}}' github.com/metacubex/gvisor)"
cp -R "$GVISOR_DIR" "$WORK/gvisor"
chmod -R u+w "$WORK/gvisor"
patch -s -p1 -d "$WORK/gvisor" < "$ROOT/scripts/gvisor-fdbased.patch"
go mod edit -modfile "$WORK/go.mod" \
  "-replace=github.com/metacubex/mihomo=$WORK/mihomo" \
  "-replace=github.com/metacubex/gvisor=$WORK/gvisor"

quickjs_dir="$(bash "$ROOT/scripts/prepare-quickjs.sh")"
export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -I \"$quickjs_dir\""

# 不使用补丁版 Go，也不覆盖手机构建产物；-a 防止编译缓存跳过代码提取。
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC="$LLVM/aarch64-unknown-linux-ohos-clang" \
  CXX="$LLVM/aarch64-unknown-linux-ohos-clang++" \
  go build -a -tags with_gvisor -buildmode=c-shared -modfile "$WORK/go.mod" \
    -o "$WORK/libclash.so" .
echo "CodeQL 分析构建完成（标准 Go、补丁依赖、临时产物）"
