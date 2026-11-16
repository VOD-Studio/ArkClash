#!/usr/bin/env bash
# 宿主用例执行真实数据层源码，平台替身只用于本机故障注入。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
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
cd "$ROOT"
"$OHPM" install --all
if [[ $# -eq 0 ]]; then
  set -- "$ROOT"/scripts/verify-*.mjs
else
  test_files=()
  for test_name in "$@"; do
    test_files+=("$ROOT/scripts/verify-$test_name.mjs")
  done
  set -- "${test_files[@]}"
fi
node --test "$@"
