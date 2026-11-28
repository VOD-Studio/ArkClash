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
bash "$ROOT/scripts/core/prepare-deps.sh" "$WORK"
export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -I \"$WORK/quickjs\""
cd "$ROOT/core"

# 不使用补丁版 Go，也不覆盖手机构建产物；-a 防止编译缓存跳过代码提取。
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC="$LLVM/aarch64-unknown-linux-ohos-clang" \
  CXX="$LLVM/aarch64-unknown-linux-ohos-clang++" \
  go build -a -tags with_gvisor,ohos -buildmode=c-shared -modfile "$WORK/go.mod" \
    -o "$WORK/libclash.so" ./cmd/clash
echo "CodeQL 分析构建完成（标准 Go、补丁依赖、临时产物）"
