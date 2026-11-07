#!/usr/bin/env python3
"""检查 HAP 的内容和体积，输出 Markdown 表格（CI 里追加到运行摘要）。

用法：check-hap.py <hap> [--baseline <sizes.json>] [--write <sizes.json>]
  --baseline  上一次 main 构建的体积，用来显示增减
  --write     把这次的体积写出去，main 上保存为下一次的基线

内核体积直接影响加载耗时（产品底线里的连接速度），所以设上限：超出时构建失败。
增长是有意的，就在 PR 里说明原因，再调高 BUDGET。
"""
import argparse
import json
import pathlib
import sys
import zipfile

REQUIRED = [
    "module.json",
    "ets/modules.abc",
    "libs/arm64-v8a/libclash.so",
    "libs/arm64-v8a/libarkclash.so",
    "libs/arm64-v8a/libc++_shared.so",
    "resources/rawfile/geo/geoip.metadb",
    "resources/rawfile/geo/geosite.dat",
    "resources/rawfile/geo/VERSION",
]
# 字节。2026-11 时 HAP 约 78.1 MB、libclash.so 约 63.9 MB，留 10% 左右余量。
BUDGET = {
    "HAP": 86_000_000,
    "libs/arm64-v8a/libclash.so": 70_000_000,
}
TRACKED = ["HAP", "libs/arm64-v8a/libclash.so", "resources/rawfile/geo/geoip.metadb", "resources/rawfile/geo/geosite.dat"]


def mb(n: int) -> str:
    return f"{n / 1_000_000:.2f} MB"


def delta(now: int, before: int | None) -> str:
    if before is None:
        return "—"
    d = now - before
    if d == 0:
        return "不变"
    return f"{'+' if d > 0 else '−'}{abs(d) / 1_000_000:.2f} MB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("hap")
    ap.add_argument("--baseline")
    ap.add_argument("--write")
    args = ap.parse_args()

    hap = pathlib.Path(args.hap)
    with zipfile.ZipFile(hap) as z:
        entries = {i.filename: i.file_size for i in z.infolist()}
    sizes = {"HAP": hap.stat().st_size, **{k: v for k, v in entries.items() if k in TRACKED}}

    baseline = {}
    if args.baseline and pathlib.Path(args.baseline).is_file():
        baseline = json.loads(pathlib.Path(args.baseline).read_text())

    errors = [f"缺少 `{name}`" for name in REQUIRED if name not in entries]
    print(f"### {hap.name}\n")
    print("| 内容 | 大小 | 相比 main | 上限 |")
    print("|---|---|---|---|")
    for name in TRACKED:
        if name not in sizes:
            continue
        limit = BUDGET.get(name)
        if limit is not None and sizes[name] > limit:
            errors.append(f"`{name}` 是 {mb(sizes[name])}，超过上限 {mb(limit)}")
        print(f"| `{name}` | {mb(sizes[name])} | {delta(sizes[name], baseline.get(name))} | {mb(limit) if limit else '—'} |")
    print()

    if args.write:
        pathlib.Path(args.write).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.write).write_text(json.dumps(sizes, indent=2))

    if errors:
        print("**检查失败：**\n")
        for e in errors:
            print(f"- {e}")
        print()
        for e in errors:
            print(f"::error title=HAP 检查::{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
