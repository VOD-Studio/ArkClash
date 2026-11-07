#!/usr/bin/env bash
# 打包 HAP，产物复制到 dist/。用法：build-hap.sh [debug|release]
# build-profile.json5 里配置了签名时，同时产出签名版。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
MODE="${1:-debug}"
cd "$ROOT"

if [[ ! -f entry/libs/arm64-v8a/libclash.so ]]; then
  echo "缺少 libclash.so，先运行 make core" >&2
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
# 同版本同模式的旧包也删掉：这次没签名时，留下的旧签名包会被 device.sh 当成这次的装上去。
rm -f dist/ArkClash-"$VERSION"-"$MODE"-*.hap
cp "$OUTPUTS/entry-default-unsigned.hap" "dist/ArkClash-$VERSION-$MODE-unsigned.hap"
if [[ -f "$OUTPUTS/entry-default-signed.hap" ]]; then
  cp "$OUTPUTS/entry-default-signed.hap" "dist/ArkClash-$VERSION-$MODE-signed.hap"
fi
ls -lh dist/ArkClash-"$VERSION"-"$MODE"-*.hap
