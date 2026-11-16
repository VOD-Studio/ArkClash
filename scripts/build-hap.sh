#!/usr/bin/env bash
# 打包 HAP，产物复制到 dist/。用法：ABI=arm64-v8a|x86_64 build-hap.sh [debug|release]
# build-profile.json5 里配置了签名时，同时产出签名版。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
MODE="${1:-debug}"
export ABI="${ABI-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ABI_SUFFIX="" ;;
  x86_64) ABI_SUFFIX="-x86_64" ;;
  *)
    echo "不支持的 ABI：${ABI}（仅支持 arm64-v8a、x86_64）" >&2
    exit 1
    ;;
esac
cd "$ROOT"

if [[ ! -f "entry/libs/$ABI/libclash.so" ]]; then
  echo "缺少 entry/libs/$ABI/libclash.so，先运行 make core ABI=$ABI" >&2
  exit 1
fi
if [[ ! -f entry/src/main/resources/rawfile/geo/VERSION ]]; then
  echo "警告：没有 Geo 数据或版本标记，内核首次启动会去 GitHub 下载（make geodata 可内置）" >&2
fi

OUTPUTS=entry/build/default/outputs/default
# 清掉上次的产物，避免把旧的签名包当成这次的。
rm -rf "$OUTPUTS"
"$OHPM" install --all
"$HVIGORW" assembleHap --mode module -p product=default -p buildMode="$MODE" --no-daemon

VERSION="$(sed -nE 's/.*"versionName": *"([^"]+)".*/\1/p' AppScope/app.json5)"
mkdir -p dist
# 只清理当前 ABI：保留另一架构的包，但不让旧签名包冒充本次产物。
PACKAGE="dist/ArkClash-$VERSION-$MODE$ABI_SUFFIX"
rm -f "$PACKAGE"-{unsigned,signed}.hap
cp "$OUTPUTS/entry-default-unsigned.hap" "$PACKAGE-unsigned.hap"
artifacts=("$PACKAGE-unsigned.hap")
if [[ -f "$OUTPUTS/entry-default-signed.hap" ]]; then
  cp "$OUTPUTS/entry-default-signed.hap" "$PACKAGE-signed.hap"
  artifacts+=("$PACKAGE-signed.hap")
fi
ls -lh "${artifacts[@]}"
