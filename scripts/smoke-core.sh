#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
ABI="${ABI:-arm64-v8a}"
LLVM="$OHOS_SDK/native/llvm/bin"

case "$ABI" in
  arm64-v8a)
    triple=aarch64-unknown-linux-ohos
    machine=AArch64
    ;;
  x86_64)
    triple=x86_64-unknown-linux-ohos
    machine='Advanced Micro Devices X86-64'
    ;;
  *)
    echo "Unsupported ABI: $ABI (use arm64-v8a or x86_64)" >&2
    exit 1
    ;;
esac

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT=gtimeout
else
  echo "core-smoke requires GNU timeout (on macOS: brew install coreutils)" >&2
  exit 1
fi
for tool in "$LLVM/$triple-clang" "$LLVM/llvm-readelf" "$HDC"; do
  if [[ ! -x "$tool" ]]; then
    echo "Missing tool: $tool; set HARMONYOS_TOOLS_HOME/OHOS_SDK" >&2
    exit 1
  fi
done
LIBRARY="$ROOT/entry/libs/$ABI/libclash.so"
if [[ ! -f "$LIBRARY" ]]; then
  echo "Missing $LIBRARY; run make core ABI=$ABI first" >&2
  exit 1
fi

check_machine() {
  local header actual
  header="$("$TIMEOUT" -k 2s 10s "$LLVM/llvm-readelf" -h "$1")"
  actual="$(awk -F: '/^[[:space:]]*Machine:/ { sub(/^[[:space:]]+/, "", $2); print $2 }' <<<"$header")"
  if [[ "$actual" != "$machine" ]] || ! grep -Eq 'Class:[[:space:]]+ELF64' <<<"$header"; then
    echo "ELF architecture mismatch for $1: expected $ABI ($machine), got $actual" >&2
    exit 1
  fi
}
check_machine "$LIBRARY"

TARGET="${HDC_TARGET:-}"
if [[ -z "$TARGET" ]]; then
  target_list="$("$TIMEOUT" -k 2s 15s "$HDC" list targets)"
  targets=()
  while IFS= read -r target; do
    target="${target//$'\r'/}"
    [[ -z "$target" || "$target" == '[Empty]' ]] && continue
    targets+=("$target")
  done <<<"$target_list"
  if [[ ${#targets[@]} -ne 1 ]]; then
    echo "core-smoke needs one connected device, or set HDC_TARGET explicitly" >&2
    exit 1
  fi
  TARGET="${targets[0]}"
fi
hdc_command() {
  "$TIMEOUT" -k 2s 60s "$HDC" -t "$TARGET" "$@"
}
device_abis="$(hdc_command shell param get const.product.cpu.abilist)"
device_abis="${device_abis//$'\r'/}"
if ! tr ',[:space:]' '\n' <<<"$device_abis" | grep -Fxq "$ABI"; then
  echo "Device ABI does not include $ABI; refusing to upload smoke artifacts" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arkclash-core-smoke.XXXXXXXX")"
REMOTE="/data/local/tmp/arkclash-core-smoke-${WORK##*.}"
remote_owned=0
cleanup() {
  local status=$? cleanup_output
  trap - EXIT INT TERM
  if [[ "$remote_owned" == 1 ]]; then
    # 只终止本次目录里的可执行文件，不能误杀已复用 PID 的其他进程。
    if ! cleanup_output="$("$TIMEOUT" -k 2s 10s "$HDC" -t "$TARGET" shell "
      if [ -f '$REMOTE/pid' ]; then
        pid=\$(cat '$REMOTE/pid')
        case \"\$pid\" in
          ''|*[!0-9]*) ;;
          *)
            if [ \"\$(readlink /proc/\$pid/exe)\" = '$REMOTE/core-smoke' ]; then
              kill -KILL \"\$pid\" 2>/dev/null || true
            fi
            ;;
        esac
      fi
      rm -rf '$REMOTE' && printf '\\nARKCLASH_CORE_SMOKE_CLEANED\\n'
    " 2>&1)" || ! grep -Fxq 'ARKCLASH_CORE_SMOKE_CLEANED' <<<"${cleanup_output//$'\r'/}"; then
      echo "Could not confirm remote smoke cleanup: $REMOTE" >&2
      status=1
    fi
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$TIMEOUT" -k 2s 60s "$LLVM/$triple-clang" \
  -std=c11 -O2 -Wall -Wextra -Werror -fPIE -pie -pthread \
  -I "$ROOT/core" "$ROOT/scripts/core/smoke.c" -ldl -o "$WORK/core-smoke"
check_machine "$WORK/core-smoke"

created="$(hdc_command shell "mkdir '$REMOTE' && printf '\\nARKCLASH_CORE_SMOKE_CREATED\\n'")"
if ! grep -Fxq 'ARKCLASH_CORE_SMOKE_CREATED' <<<"${created//$'\r'/}"; then
  echo "Could not create unique remote smoke directory" >&2
  exit 1
fi
remote_owned=1
hdc_command file send "$WORK/core-smoke" "$REMOTE/core-smoke"
hdc_command file send "$LIBRARY" "$REMOTE/libclash.so"

# hdc 的退出状态不总是远端命令状态，必须同时核对远端退出码和断言成功行。
if ! hdc_command shell "
  (
    cd '$REMOTE' || exit 1
    chmod 700 core-smoke || exit 1
    ulimit -c 0 || exit 1
    ./core-smoke '$REMOTE/libclash.so' &
    pid=\$!
    printf '%s\\n' \"\$pid\" > pid
    wait \"\$pid\"
    status=\$?
    rm -f pid
    exit \"\$status\"
  )
  status=\$?
  printf '\\nARKCLASH_CORE_SMOKE_EXIT:%s\\n' \"\$status\"
" | tee "$WORK/result"; then
  echo "core-smoke hdc failed or exceeded the 60-second host deadline" >&2
  exit 1
fi
tr -d '\r' < "$WORK/result" > "$WORK/result.clean"
if ! grep -Fxq 'ARKCLASH_CORE_SMOKE_EXIT:0' "$WORK/result.clean" ||
   ! grep -Eq '^core-smoke: PASS pre_threads=[1-9][0-9]* post_threads=[1-9][0-9]* iterations=[1-9][0-9]* api_calls=[1-9][0-9]* elapsed_ms=[0-9]+\.[0-9]+$' "$WORK/result.clean"; then
  echo "core-smoke failed: missing successful assertions or remote exit status" >&2
  exit 1
fi
