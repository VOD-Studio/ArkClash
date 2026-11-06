#!/usr/bin/env bash
# 下载 mihomo 用的 Geo 数据，打包进 HAP 的 rawfile。
# 内核启动时如果找不到这些文件会去 GitHub 现场下载，国内经常失败，也拖慢首次连接。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/entry/src/main/resources/rawfile/geo"
BASE="${GEODATA_BASE_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest}"

mkdir -p "$OUT"
# geoip.metadb 给 GEOIP 规则用，geosite.dat 给 GEOSITE 规则用。
for name in geoip.metadb geosite.dat; do
  echo "downloading $name"
  # GitHub 下载经常中途断开：失败就从断点续传重试。
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -C - --max-time 600 \
    -o "$OUT/$name.tmp" "$BASE/$name"
  mv "$OUT/$name.tmp" "$OUT/$name"
done
ls -lh "$OUT"
