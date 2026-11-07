#!/usr/bin/env bash
# 下载固定版本的 actionlint 并校验哈希，装到指定目录。CI 用；本机可以 brew install actionlint。
# 用法：install-actionlint.sh <目录>
set -euo pipefail

VERSION="1.7.12"
SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8" # linux_amd64
DIR="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TARBALL="actionlint_${VERSION}_linux_amd64.tar.gz"
curl -fsSL --retry 3 -o "$TMP/$TARBALL" "https://github.com/rhysd/actionlint/releases/download/v$VERSION/$TARBALL"
echo "$SHA256  $TMP/$TARBALL" | shasum -a 256 -c - >/dev/null
mkdir -p "$DIR"
tar -xzf "$TMP/$TARBALL" -C "$DIR" actionlint
"$DIR/actionlint" -version | head -1
