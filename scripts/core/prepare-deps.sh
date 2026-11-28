#!/usr/bin/env bash
# 为构建、静态检查、CodeQL、宿主回归与编辑器准备统一的补丁依赖，不修改模块缓存或 core/go.mod。
# 用法：scripts/core/prepare-deps.sh <目标目录>，完成后目标目录里有：
#   gvisor/ mihomo/ tailscale/  打过 patches/<模块>/series 的模块副本
#   go.mod go.sum              replace 到这些副本的临时 modfile，用 -modfile 传给 go
#   quickjs                    指向 QuickJS 源码，cgo 编译时加 -I <目标目录>/quickjs
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "用法：$0 <目标目录>" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go$(cat "$ROOT/.go-version")}"

mkdir -p "$1"
DEST="$(cd "$1" && pwd)"
rm -rf "$DEST/gvisor" "$DEST/mihomo" "$DEST/tailscale" "$DEST/go.mod" "$DEST/go.sum" "$DEST/quickjs"

# series 每行一个补丁，按顺序应用；# 开头为注释。目录里有补丁没登记时报错，避免被悄悄跳过。
apply_series() {
  local dir="$1" dest="$2" name patch
  local -a listed=()
  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ ! -f "$dir/$name" ]]; then
      echo "${dir#"$ROOT"/}/series 登记的 $name 不存在" >&2
      exit 1
    fi
    listed+=("$name")
  done <"$dir/series"
  for patch in "$dir"/*.patch; do
    if [[ " ${listed[*]} " != *" ${patch##*/} "* ]]; then
      echo "${patch#"$ROOT"/} 没有登记在同目录的 series 里" >&2
      exit 1
    fi
  done
  for name in "${listed[@]}"; do
    patch -s -p1 -d "$dest" <"$dir/$name"
  done
}

cd "$ROOT/core"
cp go.mod go.sum "$DEST/"
chmod u+w "$DEST/go.mod" "$DEST/go.sum"

replaces=()
for module in gvisor mihomo tailscale; do
  path="github.com/metacubex/$module"
  # go list -m 只在模块已下载时才返回目录，全新环境（CI）要先下载。
  go mod download "$path"
  cp -R "$(go list -m -f '{{.Dir}}' "$path")" "$DEST/$module"
  chmod -R u+w "$DEST/$module"
  apply_series "$HERE/patches/$module" "$DEST/$module"
  replaces+=("-replace=$path=$DEST/$module")
done
# 日志脱敏模板要从打完补丁的 mihomo 源码里提取。
go run "$HERE/log-templates.go" "$DEST/mihomo"
go mod edit -modfile "$DEST/go.mod" "${replaces[@]}"

ln -s "$(bash "$HERE/prepare-quickjs.sh")" "$DEST/quickjs"
