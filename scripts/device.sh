#!/usr/bin/env bash
# 真机操作。用法：device.sh install|start|log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
BUNDLE="$(sed -nE 's/.*"bundleName": *"([^"]+)".*/\1/p' "$ROOT/AppScope/app.json5")"

case "${1:-}" in
  install)
    # 装最近一次打出的签名包；未签名的包装不上真机。
    # 文件名由 build-hap.sh 生成，不含特殊字符，可以用 ls 排序。
    # shellcheck disable=SC2012
    hap="$(ls -t "$ROOT"/dist/*-signed.hap 2>/dev/null | head -1 || true)"
    if [[ -z "$hap" ]]; then
      echo "dist/ 里没有签名包：先在 DevEco Studio 配置签名，再 make hap" >&2
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
    echo "用法：$0 install|start|log" >&2
    exit 1
    ;;
esac
