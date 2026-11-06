#!/usr/bin/env bash
# 把 dist/ 里的 HAP 改成发布用的文件名，生成 SHA256SUMS，上传到指定的 Release。
# 用法：publish-release.sh <tag>，需要 GH_TOKEN 有 contents: write。
set -euo pipefail

TAG="$1"
VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"

cp "$ROOT/dist/ArkClash-$VERSION-release-unsigned.hap" "$OUT/ArkClash-$VERSION-unsigned.hap"
if [[ -f "$ROOT/dist/ArkClash-$VERSION-debug-signed.hap" ]]; then
  cp "$ROOT/dist/ArkClash-$VERSION-debug-signed.hap" "$OUT/ArkClash-$VERSION-debug-signed.hap"
fi

cd "$OUT"
sha256sum ./*.hap > SHA256SUMS
cat SHA256SUMS
gh release upload "$TAG" ./*.hap SHA256SUMS --clobber
