#!/usr/bin/env bash
# CI 里还原调试签名：解开 HARMONYOS_SIGNING_BUNDLE（由 export-signing-bundle.sh 生成），
# 把 signingConfigs 写进工作区的 build-profile.json5，只影响这次构建。
# 用法：setup-signing.sh <存放签名文件的临时目录>
set -euo pipefail

: "${HARMONYOS_SIGNING_BUNDLE:?需要 HARMONYOS_SIGNING_BUNDLE}"
DIR="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$DIR"
chmod 700 "$DIR"
printf '%s' "$HARMONYOS_SIGNING_BUNDLE" | base64 -d | tar -xzf - -C "$DIR"

python3 - "$DIR" "$ROOT/build-profile.json5" <<'PY'
import json
import pathlib
import sys

sign_dir = pathlib.Path(sys.argv[1])
profile = pathlib.Path(sys.argv[2])
config = json.loads((sign_dir / "signing.json").read_text())
material = config["material"]
# hvigor 到 storeFile 同目录下的 material/ 里找解密密码用的密钥，所以文件要放在一起。
for key in ("storeFile", "certpath", "profile"):
    material[key] = str(sign_dir / material[key])

text = profile.read_text()
empty = '"signingConfigs": [],'
if text.count(empty) != 1:
    sys.exit("build-profile.json5 里的 signingConfigs 不是空数组，不能注入")
profile.write_text(text.replace(empty, '"signingConfigs": ' + json.dumps([config]) + ","))
print("已注入签名配置：" + config["name"])
PY
