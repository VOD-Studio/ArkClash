#!/usr/bin/env bash
# 手机、vet 和宿主回归使用同一份 netmon 平台钩子。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dest="$1"
modfile="$2"
cd "$ROOT/core"
go mod download github.com/metacubex/tailscale
module_dir="$(go list -m -f '{{.Dir}}' github.com/metacubex/tailscale)"
cp -R "$module_dir" "$dest"
chmod -R u+w "$dest"
patch -s -p1 -d "$dest" < "$ROOT/scripts/tailscale-netmon.patch"
patch -s -p1 -d "$dest" < "$ROOT/scripts/tailscale-login-url.patch"
go mod edit -modfile "$modfile" "-replace=github.com/metacubex/tailscale=$dest"
