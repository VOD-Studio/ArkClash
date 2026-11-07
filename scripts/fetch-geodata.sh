#!/usr/bin/env bash
# 按 geodata.lock 下载 mihomo 用的 Geo 数据，打包进 HAP 的 rawfile。
# 内核启动时如果找不到这些文件会去 GitHub 现场下载，国内经常失败，也拖慢首次连接。
# 已有且哈希一致的文件不重复下载；锁文件由 scripts/update-geodata.sh 维护。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/entry/src/main/resources/rawfile/geo"
mkdir -p "$OUT"

names=()
while read -r name sha url; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  names+=("$name")
  if [[ -f "$OUT/$name" && "$(shasum -a 256 "$OUT/$name" | awk '{print $1}')" == "$sha" ]]; then
    continue
  fi
  echo "downloading $name"
  # GitHub 下载偶尔中途断开：失败就从断点续传重试。
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -C - --max-time 600 -o "$OUT/$name.tmp" "$url"
  actual="$(shasum -a 256 "$OUT/$name.tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$OUT/$name.tmp"
    echo "$name 校验失败：期望 ${sha}，实际 $actual" >&2
    exit 1
  fi
  mv "$OUT/$name.tmp" "$OUT/$name"
done < "$ROOT/geodata.lock"

# 版本标记：GeoData.ets 拿它和设备上已复制的比对，内容变了才重新复制。
(cd "$OUT" && shasum -a 256 "${names[@]}") > "$OUT/VERSION"
ls -lh "$OUT"
