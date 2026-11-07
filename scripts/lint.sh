#!/usr/bin/env bash
# 代码检查。用法：lint.sh [go] [shell] [arch] [arkts]，不带参数时全部检查。
# 缺少某个工具时跳过对应检查并提示；CI 里这些工具都齐全。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
cd "$ROOT"

checks=("$@")
if [[ ${#checks[@]} -eq 0 || "${checks[0]}" == "all" ]]; then
  checks=(go shell arch arkts)
fi
failed=0

lint_go() {
  echo "== gofmt"
  local unformatted
  unformatted="$(gofmt -l core)"
  if [[ -n "$unformatted" ]]; then
    echo "需要 gofmt：$unformatted" >&2
    failed=1
  fi

  echo "== go vet"
  # 内核用 cgo 引用 OHOS NDK 的头文件，vet 也要用 NDK 的编译器。
  local clang="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
  if [[ -x "$clang" ]]; then
    (cd core && CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="$clang" go vet -tags with_gvisor ./...) || failed=1
  else
    echo "跳过：找不到 OHOS NDK（${clang}）"
  fi
}

lint_shell() {
  echo "== shellcheck"
  if command -v shellcheck >/dev/null; then
    find scripts -name '*.sh' -print0 | xargs -0 shellcheck || failed=1
  else
    echo "跳过：没有安装 shellcheck"
  fi

  echo "== 变量后紧跟中文"
  # UTF-8 环境下 bash 会把紧跟在变量名后面的中文字节也算进变量名："$x，" 读的不是 x，
  # set -u 时直接报 unbound variable。shellcheck 查不出来，这里单独查：要写成 "${x}，"。
  local hits
  hits="$(LC_ALL=C grep -rnE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' scripts .github Makefile \
    --include='*.sh' --include='*.yml' --include=Makefile | LC_ALL=C grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$hits" ]]; then
    echo "$hits" >&2
    echo "变量后紧跟中文时加花括号，写成 \${var}" >&2
    failed=1
  fi
}

lint_arch() {
  echo "== 分层规则"
  python3 scripts/check-arch.py || failed=1
}

lint_arkts() {
  echo "== codelinter"
  if [[ -n "${CODELINTER:-}" && -x "$CODELINTER" ]]; then
    # -e error：有错误级别的问题时返回非零；警告只提示，不拦截。
    "$CODELINTER" -c code-linter.json5 -e error . || failed=1
  else
    echo "跳过：codelinter 只在 Command Line Tools 里有（CI 会跑）"
  fi
}

for check in "${checks[@]}"; do
  case "$check" in
    go) lint_go ;;
    shell) lint_shell ;;
    arch) lint_arch ;;
    arkts) lint_arkts ;;
    *) echo "未知检查：$check" >&2; exit 2 ;;
  esac
done
exit "$failed"
