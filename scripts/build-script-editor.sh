#!/usr/bin/env bash
# 编辑器是离线 ArkWeb 资源，依赖和完整性由 npm 锁文件固定。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDITOR="$ROOT/scripts/script-editor"
ASSETS="$ROOT/entry/src/main/resources/rawfile/script-editor"
cd "$EDITOR"
npm ci --ignore-scripts --no-audit --no-fund
node node_modules/esbuild/bin/esbuild editor.mjs --bundle --minify --legal-comments=none --target=chrome100 \
  --outfile="$ASSETS/editor.js"
node --input-type=module - "$ASSETS/third-party.txt" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const lock = JSON.parse(readFileSync('package-lock.json', 'utf8'));
const lines = [];
for (const name of Object.keys(lock.packages)) {
  if (!name || lock.packages[name].dev) continue;
  const license = readFileSync(join(name, 'LICENSE'), 'utf8');
  lines.push(`${name.replace(/^node_modules\//, '')} ${lock.packages[name].version}\n${license}`);
}
writeFileSync(process.argv[2], lines.join('\n'));
JS
