#!/usr/bin/env bash
# 下载 FlClash v0.9.3 使用的 QuickJS-NG 源码，Rust 包只作为固定源码归档。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
version=0.12.2
checksum=a13ac243b86a74120814ef7e9e30ad5a2c1199b7b9963b1cf7c84e4cdc1cad99
cache="$ROOT/.toolchain"
source_dir="$cache/quickjs-hidden-v1-$version-$checksum"
if [[ ! -f "$source_dir/quickjs.c" ]]; then
  mkdir -p "$cache"
  work="$(mktemp -d "$cache/quickjs.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://static.crates.io/crates/rquickjs-sys/rquickjs-sys-$version.crate" -o "$work/source.crate"
  actual="$(shasum -a 256 "$work/source.crate" | cut -d ' ' -f 1)"
  [[ "$actual" == "$checksum" ]] || { echo 'QuickJS 源码校验和不符' >&2; exit 1; }
  tar -xzf "$work/source.crate" -C "$work" "rquickjs-sys-$version/quickjs"
  # 并行构建可能已经刚发布相同依赖，完整目录从临时路径原子改名。
  python3 - "$work/rquickjs-sys-$version/quickjs" "$source_dir" <<'PY'
import errno
import os
import sys
from pathlib import Path

header = Path(sys.argv[1]) / 'quickjs.h'
text = header.read_text()
public = '#  define JS_EXTERN __attribute__((visibility("default")))'
if text.count(public) != 1:
    raise SystemExit('QuickJS API 可见性声明已改变')
header.write_text(text.replace(public, public.replace('"default"', '"hidden"')))

try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as error:
    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not os.path.isfile(os.path.join(sys.argv[2], 'quickjs.c')):
        raise
PY
fi
printf '%s\n' "$source_dir"
