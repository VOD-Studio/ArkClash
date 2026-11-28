#!/usr/bin/env bash
# 宿主用例执行真实数据层源码，平台替身只用于本机故障注入。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -eq 1 && $1 == go ]]; then
  cd "$ROOT/core"
  CGO_ENABLED=0 GOTOOLCHAIN="go$(cat "$ROOT/.go-version")" go test -mod=readonly ./internal/backup
  exit
fi

if [[ $# -eq 1 && $1 == core ]]; then
  exec node --test "$ROOT/scripts/tests/core.test.mjs"
fi

if [[ $# -eq 1 && $1 == local ]]; then
  case "$(uname -s)" in
    Darwin|MINGW*|MSYS*|CYGWIN*) ;;
    *)
      echo 'SKIP: DevEco ArkTS Local Test 需要 macOS 或 Windows。此宿主可运行 make test TESTS=contracts。'
      exit
      ;;
  esac
fi

# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
cd "$ROOT"

if [[ $# -eq 1 && $1 == local ]]; then
  if [[ -f "${OHPM}.bat" ]]; then
    cmd.exe //d //s //c "\"\"$(cygpath -w "${OHPM}.bat")\" install --all\""
    HVIGORW="$(cygpath -w "${HVIGORW}.bat")"
    export HVIGORW
  else
    "$OHPM" install --all
  fi
  node "$ROOT/scripts/tests/run-local.mjs"
  exit
fi

# 用例名对应 scripts/tests/<名字>.test.mjs，先解析再装依赖，写错名字时立即退出。
if [[ $# -eq 0 ]]; then
  set -- "$ROOT"/scripts/tests/*.test.mjs
else
  test_files=()
  for test_name in "$@"; do
    if [[ ! -f "$ROOT/scripts/tests/$test_name.test.mjs" ]]; then
      known=("$ROOT"/scripts/tests/*.test.mjs)
      known=("${known[@]##*/}")
      echo "没有宿主用例 ${test_name}，可选：${known[*]%.test.mjs}" >&2
      exit 2
    fi
    test_files+=("$ROOT/scripts/tests/$test_name.test.mjs")
  done
  set -- "${test_files[@]}"
fi

if [[ -z "${ARKCLASH_TYPESCRIPT:-}" ]]; then
  ARKCLASH_TYPESCRIPT="$(_find_tool "$_tools_home" typescript.js \
    hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js \
    tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js)"
fi
if [[ ! -f "$ARKCLASH_TYPESCRIPT" ]]; then
  echo '未找到 TypeScript 编译器；请通过 ARKCLASH_TYPESCRIPT 指定 DevEco 工具链中的 typescript.js' >&2
  exit 1
fi
export ARKCLASH_TYPESCRIPT
"$OHPM" install --all
exec node --test "$@"
