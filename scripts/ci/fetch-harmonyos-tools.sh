#!/usr/bin/env bash
# 从私有仓库的 Release 下载 HarmonyOS Command Line Tools（Linux x64）并解压，最后输出工具根目录。
# 用法：fetch-harmonyos-tools.sh <仓库> <tag> <输出目录>，GH_TOKEN 要能读这个仓库。
# 华为 SDK 不允许公开分发，这个 Release 必须放在私有仓库里，见 docs/ci.md。
set -euo pipefail

REPO="$1"
TAG="$2"
OUT="$3"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/harmonyos-tools.XXXX")"
trap 'rm -rf "$TMP"' EXIT

gh release download "$TAG" -R "$REPO" -D "$TMP" -p 'commandline-tools-linux-x64-*' -p 'SHA256'

# 单个附件不能超过 2GB，超过时按 .zip.part-aa、-ab… 分卷上传，这里按文件名顺序拼回去。
shopt -s nullglob
parts=("$TMP"/*.zip.part-*)
if [[ ${#parts[@]} -gt 0 ]]; then
  cat "${parts[@]}" > "$TMP/tools.zip"
  rm -f "${parts[@]}"
else
  zips=("$TMP"/commandline-tools-linux-x64-*.zip)
  mv "${zips[0]}" "$TMP/tools.zip"
fi

# SHA256 里是华为下载页公布的整包校验值。
expected="$(awk '{print $1}' "$TMP/SHA256")"
actual="$(sha256sum "$TMP/tools.zip" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  echo "Command Line Tools 校验失败：期望 ${expected}，实际 $actual" >&2
  exit 1
fi

mkdir -p "$OUT"
unzip -q "$TMP/tools.zip" -d "$OUT"
rm -f "$TMP/tools.zip"
# 顶层目录名随版本变化，以 sdk/default 所在位置为准。
sdk_default="$(find "$OUT" -maxdepth 4 -type d -path '*/sdk/default' | head -1)"
if [[ -z "$sdk_default" ]]; then
  echo "解压后找不到 sdk/default，Command Line Tools 目录结构可能变了" >&2
  exit 1
fi
home="$(dirname "$(dirname "$sdk_default")")"
# 模拟器和文档工具不是 SDK 组件，打包用不到，删掉缩小缓存。
# previewer 虽然也用不到，但 hvigor 会检查 SDK 组件是否齐全，不能删。
rm -rf "$home/emulator" "$home/arktsdoc"
# zip 不一定保留可执行权限。
find "$home" -type f \( -path '*/bin/*' -o -name '*.sh' \) -exec chmod +x {} +
echo "$home"
