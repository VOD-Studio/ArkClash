#!/usr/bin/env bash
# 为构建、静态检查、CodeQL、宿主回归与编辑器准备统一的补丁依赖副本和临时 go.mod，
# 不修改模块缓存或 core/go.mod。用法：scripts/prepare-core-modfile.sh <目标目录>
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "用法：$0 <目标目录>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go$(cat "$ROOT/.go-version")}"

mkdir -p "$1"
DEST="$(cd "$1" && pwd)"
rm -rf "$DEST/mihomo" "$DEST/tailscale" "$DEST/gvisor" "$DEST/go.mod" "$DEST/go.sum"

cd "$ROOT/core"
cp go.mod go.sum "$DEST/"
chmod u+w "$DEST/go.mod" "$DEST/go.sum"

# gvisor-fdbased.patch：SELinux 不允许对 TUN fd 做 fstat，见补丁里的注释。
# go list -m 只在模块已下载时才返回目录，全新环境（CI）要先下载。
go mod download github.com/metacubex/gvisor
GVISOR_DIR="$(go list -m -f '{{.Dir}}' github.com/metacubex/gvisor)"
cp -R "$GVISOR_DIR" "$DEST/gvisor"
chmod -R u+w "$DEST/gvisor"
patch -s -p1 -d "$DEST/gvisor" < "$ROOT/scripts/gvisor-fdbased.patch"

bash "$ROOT/scripts/prepare-mihomo.sh" "$DEST/mihomo"
go mod edit -modfile "$DEST/go.mod" \
  "-replace=github.com/metacubex/gvisor=$DEST/gvisor" \
  "-replace=github.com/metacubex/mihomo=$DEST/mihomo"
bash "$ROOT/scripts/prepare-tailscale.sh" "$DEST/tailscale" "$DEST/go.mod"
