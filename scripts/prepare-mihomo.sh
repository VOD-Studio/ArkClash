#!/usr/bin/env bash
# 手机构建与宿主回归共用同一份 mihomo 补丁，模块缓存保持原样。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$1"
cd "$ROOT/core"
go mod download github.com/metacubex/mihomo
MIHOMO_DIR="$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)"
cp -R "$MIHOMO_DIR" "$DEST"
chmod -R u+w "$DEST"
patch -s -p1 -d "$DEST" < "$ROOT/scripts/mihomo-urltest-cancel.patch"
patch -s -p1 -d "$DEST" < "$ROOT/scripts/mihomo-rule-dial.patch"
