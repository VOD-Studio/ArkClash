#!/usr/bin/env bash
# 代码检查。用法：lint.sh [go] [shell] [arch] [arkts] [actions] [commits] [vuln]，
# 不带参数（或 all）时跑除 vuln 以外的全部检查；vuln 要联网下载漏洞库，单独跑。
# 缺少某个工具时跳过对应检查并提示；CI 里这些工具都齐全。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
cd "$ROOT"

checks=("$@")
if [[ ${#checks[@]} -eq 0 || "${checks[0]}" == "all" ]]; then
  checks=(go shell arch arkts actions commits)
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

# workflow 静态检查（actionlint）和安全审计（zizmor：注入、权限、凭据泄露等）。
ZIZMOR_VERSION="1.32.0"
lint_actions() {
  echo "== actionlint"
  if command -v actionlint >/dev/null; then
    actionlint || failed=1
  else
    echo "跳过：没有安装 actionlint（brew install actionlint）"
  fi

  echo "== zizmor"
  # 有 GH_TOKEN 时 zizmor 会联网检查，比如固定的 SHA 是否真的属于那个 action 仓库。
  local zizmor=()
  if command -v zizmor >/dev/null; then
    zizmor=(zizmor)
  elif command -v uvx >/dev/null; then
    zizmor=(uvx "zizmor@$ZIZMOR_VERSION")
  elif command -v pipx >/dev/null; then
    zizmor=(pipx run "zizmor==$ZIZMOR_VERSION")
  fi
  if [[ ${#zizmor[@]} -gt 0 ]]; then
    "${zizmor[@]}" --quiet .github || failed=1
  else
    echo "跳过：没有 zizmor、uvx 或 pipx"
  fi
}

lint_commits() {
  echo "== 提交信息"
  # CI 传入 PR 的范围；本机默认检查当前分支相对 origin/main 的提交。
  python3 scripts/ci/check-commits.py "${COMMIT_RANGE:-origin/main..HEAD}" || failed=1
}

GOVULNCHECK_VERSION="v1.9.0"
lint_vuln() {
  echo "== govulncheck"
  # 只报告代码真正调用到的漏洞；和 go vet 一样要用 NDK 的编译器处理 cgo。
  local clang="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
  if [[ -x "$clang" ]]; then
    # govulncheck 本身按本机平台安装；分析时才切到目标平台，否则装出来的是 arm64 程序跑不了。
    GOBIN="$ROOT/.toolchain/bin" go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
    (cd core && CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="$clang" \
      "$ROOT/.toolchain/bin/govulncheck" -tags with_gvisor ./...) || failed=1
  else
    echo "跳过：找不到 OHOS NDK（${clang}）"
  fi
}

for check in "${checks[@]}"; do
  case "$check" in
    go) lint_go ;;
    shell) lint_shell ;;
    arch) lint_arch ;;
    arkts) lint_arkts ;;
    actions) lint_actions ;;
    commits) lint_commits ;;
    vuln) lint_vuln ;;
    *) echo "未知检查：$check" >&2; exit 2 ;;
  esac
done
exit "$failed"
