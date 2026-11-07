#!/usr/bin/env python3
"""检查 ArkTS 的分层依赖方向，规则见 docs/architecture.md「ArkTS 分层与依赖方向」。"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ETS = ROOT / "entry/src/main/ets"
NATIVE_LIB = "libarkclash.so"

# 每一层允许 import 的层；不在表里的层不允许出现。
ALLOWED = {
    "shared": set(),
    "client": {"shared"},
    "features": {"client", "shared", "components"},
    "components": {"shared"},
    "pages": {"features", "client", "shared", "components"},
    "entryability": {"pages"},
    "vpn": {"shared"},
}
IMPORT = re.compile(r"""^\s*import\b[^'"]*['"]([^'"]+)['"]""", re.M)


def layer_of(path: pathlib.Path) -> tuple[str, str | None]:
    """返回 (层名, feature 名)。"""
    parts = path.relative_to(ETS).parts
    feature = parts[1] if parts[0] == "features" and len(parts) > 2 else None
    return parts[0], feature


def main() -> int:
    errors = []
    for src in sorted(ETS.rglob("*.ets")):
        layer, feature = layer_of(src)
        if layer not in ALLOWED:
            errors.append(f"{src.relative_to(ROOT)}: 未登记的目录 {layer}/，先在 architecture.md 和本脚本里定义它")
            continue
        for spec in IMPORT.findall(src.read_text(encoding="utf-8")):
            if spec == NATIVE_LIB:
                if layer != "vpn":
                    errors.append(f"{src.relative_to(ROOT)}: 只有 vpn/ 可以加载 {NATIVE_LIB}")
                continue
            if not spec.startswith("."):
                continue  # 系统 Kit 等外部模块
            target = (src.parent / spec).resolve()
            try:
                target_layer, target_feature = layer_of(target.with_suffix(".ets"))
            except ValueError:
                errors.append(f"{src.relative_to(ROOT)}: import 指向 ets/ 之外：{spec}")
                continue
            if target_layer == layer:
                if layer == "features" and target_feature != feature:
                    errors.append(f"{src.relative_to(ROOT)}: feature 之间不能直接 import（{feature} → {target_feature}）")
                continue
            if target_layer not in ALLOWED[layer]:
                errors.append(f"{src.relative_to(ROOT)}: {layer}/ 不能依赖 {target_layer}/（{spec}）")
    for e in errors:
        print(e, file=sys.stderr)
    if errors:
        return 1
    print("分层检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
