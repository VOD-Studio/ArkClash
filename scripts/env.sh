# shellcheck shell=bash
# 定位 HarmonyOS 工具链，供其他脚本 source。
#   - Command Line Tools：HARMONYOS_TOOLS_HOME；也复用 DEVECO_CLI_CLT_PATH。
#   - DevEco Studio：DEVECO_HOME；macOS 默认 /Applications/DevEco-Studio.app/Contents。
#   - Linux 未指定路径时，使用 ~/.local/opt/harmonyos-clt-*/command-line-tools 下唯一的安装。
# 导出：DEVECO_SDK_HOME、OHOS_SDK（OpenHarmony SDK，内含 NDK）、HVIGORW、OHPM、HDC、CODELINTER（可能为空）。

# 在 $1 下按候选相对路径找第一个存在的文件，都没有再按文件名搜索。
_find_tool() {
  local home="$1" name="$2"; shift 2
  local rel
  for rel in "$@"; do
    if [[ -e "$home/$rel" ]]; then
      echo "$home/$rel"
      return
    fi
  done
  find "$home" -maxdepth 5 -name "$name" -type f 2>/dev/null | head -1
}

_tools_home="${HARMONYOS_TOOLS_HOME:-}"
if [[ -z "$_tools_home" && -z "${DEVECO_HOME:-}" ]]; then
  _tools_home="${DEVECO_CLI_CLT_PATH:-}"
  if [[ -z "$_tools_home" && "${OSTYPE:-}" == linux* ]]; then
    for _candidate in "$HOME"/.local/opt/harmonyos-clt-*/command-line-tools; do
      [[ -d "$_candidate" ]] || continue
      if [[ -n "$_tools_home" ]]; then
        echo "找到多个 HarmonyOS Command Line Tools，请设置 HARMONYOS_TOOLS_HOME 选择安装目录" >&2
        return 1
      fi
      _tools_home="$_candidate"
    done
  fi
fi

if [[ -n "$_tools_home" ]]; then
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$_tools_home/sdk}"
  HVIGORW="$(_find_tool "$_tools_home" hvigorw bin/hvigorw hvigor/bin/hvigorw)"
  OHPM="$(_find_tool "$_tools_home" ohpm bin/ohpm ohpm/bin/ohpm)"
  CODELINTER="$(_find_tool "$_tools_home" codelinter bin/codelinter codelinter/bin/codelinter)"
  _node_bin="$(dirname "$(_find_tool "$_tools_home" node tool/node/bin/node)")"
else
  _tools_home="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$_tools_home/sdk}"
  HVIGORW="$_tools_home/tools/hvigor/bin/hvigorw"
  OHPM="$_tools_home/tools/ohpm/bin/ohpm"
  # DevEco Studio 不带 codelinter 命令行，只有 Command Line Tools 有。
  CODELINTER=""
  _node_bin="$_tools_home/tools/node/bin"
fi

export OHOS_SDK="${OHOS_SDK:-$DEVECO_SDK_HOME/default/openharmony}"
HDC="$OHOS_SDK/toolchains/hdc"
_ohpm_bin="$(dirname "$OHPM")"
export PATH="$_node_bin:$_ohpm_bin:$PATH"
export HVIGORW OHPM HDC CODELINTER
