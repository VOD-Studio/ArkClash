#!/usr/bin/env bash
# 在本机把 DevEco 自动签名生成的调试证书打包成 CI 用的 HARMONYOS_SIGNING_BUNDLE（base64 输出到 stdout）。
# 用法：scripts/ci/export-signing-bundle.sh | gh secret set HARMONYOS_SIGNING_BUNDLE -R VOD-Studio/ArkClash
# 包里有私钥和解密密码用的 material，只能直接管道进 GitHub Secrets，不要写到文件或提交。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

python3 - "$ROOT/build-profile.json5" "$TMP" <<'PY'
import json
import pathlib
import re
import shutil
import sys

profile = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
# build-profile.json5 是 JSON5：去掉整行注释和尾随逗号后按 JSON 解析。
text = re.sub(r"^\s*//.*$", "", profile, flags=re.M)
text = re.sub(r"\s//[^\n\"]*$", "", text, flags=re.M)
text = re.sub(r",(\s*[}\]])", r"\1", text)
configs = json.loads(text)["app"]["signingConfigs"]
if not configs:
    sys.exit("build-profile.json5 里没有签名配置：先在 DevEco Studio 里自动签名")
config = configs[0]
material = config["material"]
# hvigor 用证书同目录下的 material/ 解密密码，要一起带走。
shutil.copytree(pathlib.Path(material["storeFile"]).parent / "material", out / "material")
for key in ("storeFile", "certpath", "profile"):
    src = pathlib.Path(material[key])
    shutil.copy2(src, out / src.name)
    material[key] = src.name
(out / "signing.json").write_text(json.dumps(config))
print("签名配置：" + config["name"] + "，证书文件：" + ", ".join(sorted(p.name for p in out.iterdir())), file=sys.stderr)
PY

tar -czf - -C "$TMP" . | base64 | tr -d '\n'
