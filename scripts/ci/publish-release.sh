#!/usr/bin/env bash
# 发布 HAP 到指定的 Release。
#   publish-release.sh prepare <tag>：把 dist/ 里 release 模式的 HAP 改成发布用的文件名，生成 SHA256SUMS
#   publish-release.sh upload <tag>：上传 dist/release/ 里的文件，并在发版说明末尾补上校验方法
# upload 需要 GH_TOKEN 有 contents: write。
set -euo pipefail

STEP="$1"
TAG="$2"
VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/dist/release"

case "$STEP" in
  prepare)
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$ROOT/dist/ArkClash-$VERSION-release-unsigned.hap" "$OUT/ArkClash-$VERSION-unsigned.hap"
    # 用维护者的调试证书签名：文件名按证书类型叫 debug-signed，包本身是 release 模式构建的。
    if [[ -f "$ROOT/dist/ArkClash-$VERSION-release-signed.hap" ]]; then
      cp "$ROOT/dist/ArkClash-$VERSION-release-signed.hap" "$OUT/ArkClash-$VERSION-debug-signed.hap"
    fi
    (cd "$OUT" && sha256sum ./*.hap > SHA256SUMS && cat SHA256SUMS)
    ;;
  upload)
    cd "$OUT"
    gh release upload "$TAG" ./*.hap SHA256SUMS --clobber
    notes="$(gh release view "$TAG" --json body --jq .body)"
    if ! grep -q '^### 校验' <<<"$notes"; then
      repo="${GITHUB_REPOSITORY:-VOD-Studio/ArkClash}"
      printf '%s\n\n### 校验\n\n- 文件完整性：`sha256sum -c SHA256SUMS`\n- 来源证明（确认安装包由本仓库的 GitHub Actions 从这个 tag 构建）：`gh attestation verify ArkClash-%s-unsigned.hap -R %s`\n' \
        "$notes" "$VERSION" "$repo" > notes.md
      gh release edit "$TAG" --notes-file notes.md
      rm -f notes.md
    fi
    ;;
  *)
    echo "用法：$0 prepare|upload <tag>" >&2
    exit 1
    ;;
esac
