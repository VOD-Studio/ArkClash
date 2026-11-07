#!/usr/bin/env bash
# 把上游最新的 Geo 数据镜像到本仓库的 geodata 预发布，并重写 geodata.lock。
# 用法：update-geodata.sh，GH_TOKEN 需要本仓库的 contents: write。每周由 scheduled.yml 运行。
#
# 为什么要镜像：上游 meta-rules-dat 的 latest Release 和 release 分支每天都被覆盖，
# 没有可以长期引用的版本。构建只认锁文件里的哈希，同一个提交任何时候构建出来都一样。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_REPO="MetaCubeX/meta-rules-dat"
UPSTREAM="https://github.com/$UPSTREAM_REPO/releases/download/latest"
REPO="${GITHUB_REPOSITORY:-VOD-Studio/ArkClash}"
MIRROR_TAG="geodata"
LOCK="$ROOT/geodata.lock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! gh release view "$MIRROR_TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$MIRROR_TAG" -R "$REPO" --prerelease --latest=false \
    --title "Geo 数据镜像（构建用，不是应用版本）" \
    --notes "构建 HAP 时按 geodata.lock 从这里下载 Geo 数据。文件名里带内容哈希，旧文件保留，历史版本可以重新构建。来源：https://github.com/$UPSTREAM_REPO"
fi
existing="$(gh release view "$MIRROR_TAG" -R "$REPO" --json assets --jq '.assets[].name')"

released="$(gh api "repos/$UPSTREAM_REPO/releases/latest" --jq .name)"
{
  echo "# Geo 数据锁文件：由 scripts/update-geodata.sh 生成，每周由机器人开 PR 更新，不要手改。"
  echo "# 上游：${UPSTREAM_REPO}，$released"
  echo "# <文件名> <sha256> <下载地址>"
} > "$TMP/lock"

# geoip.metadb 给 GEOIP 规则用，geosite.dat 给 GEOSITE 规则用。
for name in geoip.metadb geosite.dat; do
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -C - --max-time 600 -o "$TMP/$name" "$UPSTREAM/$name"
  curl -fsSL --retry 5 --retry-all-errors -o "$TMP/$name.sha256sum" "$UPSTREAM/$name.sha256sum"
  expected="$(awk '{print $1}' "$TMP/$name.sha256sum")"
  actual="$(shasum -a 256 "$TMP/$name" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    echo "$name 和上游公布的 sha256 不一致：期望 ${expected}，实际 $actual" >&2
    exit 1
  fi

  asset="${name%.*}-${actual:0:12}.${name##*.}"
  if ! grep -qxF "$asset" <<<"$existing"; then
    cp "$TMP/$name" "$TMP/$asset"
    gh release upload "$MIRROR_TAG" -R "$REPO" "$TMP/$asset"
  fi
  echo "$name $actual https://github.com/$REPO/releases/download/$MIRROR_TAG/$asset" >> "$TMP/lock"
done

if cmp -s "$TMP/lock" "$LOCK"; then
  echo "Geo 数据没有变化"
else
  mv "$TMP/lock" "$LOCK"
  echo "已更新 ${LOCK}（${released}）"
fi
