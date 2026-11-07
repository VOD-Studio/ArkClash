#!/usr/bin/env bash
# 从公开的 OpenHarmony SDK 里只取出 Linux 版 NDK（编内核用，不需要华为账号）。
# 用法：fetch-ohos-ndk.sh <发行版目录，如 7.0-Release> <压缩包内 NDK 路径> <输出目录>
# 边下载边解压，取到 NDK 后 tar 就停止读取，不用下完整个 3GB+ 的 SDK 包。
set -euo pipefail

RELEASE="$1"
MEMBER="$2"
OUT="$3"
URL="https://repo.huaweicloud.com/openharmony/os/$RELEASE/ohos-sdk-windows_linux-public.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# tar 提前退出后 curl 会因管道关闭报错（退出码 23），只看 tar 的结果。
set +o pipefail
curl -fsSL "$URL" | tar -xzf - -C "$TMP" --occurrence=1 "$MEMBER"
set -o pipefail
if [[ ! -f "$TMP/$MEMBER" ]]; then
  echo "SDK 包里没有 ${MEMBER}，检查 OpenHarmony 发行版里的 NDK 文件名" >&2
  exit 1
fi

mkdir -p "$OUT"
unzip -q "$TMP/$MEMBER" -d "$OUT"
CLANG="$OUT/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
if [[ ! -x "$CLANG" ]]; then
  echo "解压后找不到 ${CLANG}，NDK 目录结构可能变了：" >&2
  ls "$OUT" >&2
  exit 1
fi
"$CLANG" --version | head -1
