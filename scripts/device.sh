#!/usr/bin/env bash
# 真机操作。用法：device.sh install [debug|release]|start|log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
BUNDLE="$(sed -nE 's/.*"bundleName": *"([^"]+)".*/\1/p' "$ROOT/AppScope/app.json5")"

case "${1:-}" in
  install)
    # 装当前版本、指定模式的签名包，文件名和 build-hap.sh 生成的一致；未签名的包装不上真机。
    version="$(sed -nE 's/.*"versionName": *"([^"]+)".*/\1/p' "$ROOT/AppScope/app.json5")"
    hap="$ROOT/dist/ArkClash-$version-${2:-debug}-signed.hap"
    if [[ ! -f "$hap" ]]; then
      echo "没有 ${hap#"$ROOT"/}：先在 DevEco Studio 配置签名，再 make hap" >&2
      exit 1
    fi
    "$HDC" install -r "$hap"
    ;;
  start)
    "$HDC" shell aa start -a EntryAbility -b "$BUNDLE"
    ;;
  log)
    "$HDC" hilog | grep --line-buffered -E "ArkClashCore|ClashVpnAbility"
    ;;
  *)
    echo "用法：$0 install [debug|release]|start|log" >&2
    exit 1
    ;;
esac
