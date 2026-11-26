#!/usr/bin/env bash
# 真机操作。用法：ABI=arm64-v8a|x86_64 device.sh install [debug|release]|start|log|vpn-exits
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
BUNDLE="$(sed -nE 's/.*"bundleName": *"([^"]+)".*/\1/p' "$ROOT/AppScope/app.json5")"

case "${1:-}" in
  install)
    abi="${ABI-arm64-v8a}"
    case "$abi" in
      arm64-v8a) abi_suffix="" ;;
      x86_64) abi_suffix="-x86_64" ;;
      *)
        echo "不支持的 ABI：${abi}（仅支持 arm64-v8a、x86_64）" >&2
        exit 1
        ;;
    esac
    # 装当前版本、指定模式的签名包，文件名和 build-hap.sh 生成的一致；未签名的包装不上真机。
    version="$(sed -nE 's/.*"versionName": *"([^"]+)".*/\1/p' "$ROOT/AppScope/app.json5")"
    hap="$ROOT/dist/ArkClash-$version-${2:-debug}$abi_suffix-signed.hap"
    if [[ ! -f "$hap" ]]; then
      echo "没有 ${hap#"$ROOT"/}：先在 DevEco Studio 配置签名，再 make hap ABI=$abi" >&2
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
  vpn-exits)
    hdc_command=("$HDC")
    if [[ -n "${HDC_TARGET:-}" ]]; then
      hdc_command+=(-t "$HDC_TARGET")
    fi
    # 部分 HDC 版本在设备断开时也返回 0，只有设备端执行完查询才输出记录。
    report="$("${hdc_command[@]}" shell "hidumper -e --list '${BUNDLE}:vpn' -n 50 && echo ARKCLASH_QUERY_DONE")"
    report="${report//$'\r'/}"
    if [[ "$report" != *$'\nARKCLASH_QUERY_DONE' ]]; then
      echo "无法读取 VPN 退出记录，请检查 HDC 连接，多台设备时指定 HDC_TARGET。" >&2
      exit 1
    fi
    printf '%s\n' "${report%$'\nARKCLASH_QUERY_DONE'}"
    ;;
  *)
    echo "用法：$0 install [debug|release]|start|log|vpn-exits" >&2
    exit 1
    ;;
esac
