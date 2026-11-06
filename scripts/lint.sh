#!/usr/bin/env bash
# 代码检查：gofmt、go vet、shellcheck、ArkTS 分层规则、codelinter。
# 缺少某个工具时跳过对应检查并提示；CI 里这些工具都齐全。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
cd "$ROOT"
failed=0

echo "== gofmt"
unformatted="$(gofmt -l core)"
if [[ -n "$unformatted" ]]; then
  echo "需要 gofmt：$unformatted" >&2
  failed=1
fi

echo "== go vet"
# 内核用 cgo 引用 OHOS NDK 的头文件，vet 也要用 NDK 的编译器。
CLANG="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
if [[ -x "$CLANG" ]]; then
  (cd core && CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="$CLANG" go vet -tags with_gvisor ./...) || failed=1
else
  echo "跳过：找不到 OHOS NDK（$CLANG）"
fi

echo "== shellcheck"
if command -v shellcheck >/dev/null; then
  find scripts -name '*.sh' -print0 | xargs -0 shellcheck || failed=1
else
  echo "跳过：没有安装 shellcheck"
fi

echo "== 分层规则"
python3 scripts/check-arch.py || failed=1

echo "== codelinter"
if [[ -n "${CODELINTER:-}" && -x "$CODELINTER" ]]; then
  "$CODELINTER" -c code-linter.json5 entry || failed=1
else
  echo "跳过：codelinter 只在 Command Line Tools 里有（CI 会跑）"
fi

exit "$failed"
