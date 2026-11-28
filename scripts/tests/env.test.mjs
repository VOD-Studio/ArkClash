import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const envScript = fileURLToPath(new URL('../env.sh', import.meta.url));

async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), 'arkclash-env-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const env = { ...process.env, HOME: home, OSTYPE: 'linux-gnu' };
  for (const name of ['HARMONYOS_TOOLS_HOME', 'DEVECO_HOME', 'DEVECO_CLI_CLT_PATH', 'DEVECO_SDK_HOME', 'OHOS_SDK']) {
    delete env[name];
  }
  return { home, env };
}

async function install(root, studio = false) {
  const tools = studio ? join(root, 'tools') : root;
  await mkdir(join(tools, 'bin'), { recursive: true });
  const nodeBin = join(tools, studio ? 'node/bin' : 'tool/node/bin');
  await mkdir(nodeBin, { recursive: true });
  await symlink(process.execPath, join(nodeBin, 'node'));
  for (const tool of ['ohpm', 'hvigorw']) {
    const path = join(tools, studio ? `${tool === 'hvigorw' ? 'hvigor' : tool}/bin` : 'bin', tool);
    await mkdir(join(path, '..'), { recursive: true });
    await writeFile(path, '#!/usr/bin/env node\nprocess.exit(process.env.DEVECO_SDK_HOME === process.env.EXPECTED_SDK && process.env.OHOS_SDK === process.env.EXPECTED_OHOS ? 0 : 37);\n');
    await chmod(path, 0o755);
  }
  return root;
}

function run(env, expectedRoot) {
  return spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; "$OHPM"; "$HVIGORW"', 'env-test', envScript], {
    env: {
      ...env,
      EXPECTED_SDK: env.DEVECO_SDK_HOME ?? join(expectedRoot, 'sdk'),
      EXPECTED_OHOS: env.OHOS_SDK ?? join(env.DEVECO_SDK_HOME ?? join(expectedRoot, 'sdk'), 'default/openharmony')
    }, encoding: 'utf8', timeout: 10000
  });
}

test('Linux 无工具路径变量时可执行本机 CLT 的包管理和构建命令', async t => {
  const { home, env } = await fixture(t);
  const root = await install(join(home, '.local/opt/harmonyos-clt-26.0.0.865/command-line-tools'));
  const result = run(env, root);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
});

test('显式 CLT 路径优先于 Studio 和自动发现', async t => {
  const { home, env } = await fixture(t);
  await install(join(home, '.local/opt/harmonyos-clt-26.0.0.865/command-line-tools'));
  const root = await install(join(home, 'custom tools'));
  const result = run({ ...env, HARMONYOS_TOOLS_HOME: root, DEVECO_HOME: join(home, 'unused') }, root);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
});

test('显式 Studio 路径优先于 CLI 的 CLT 路径', async t => {
  const { home, env } = await fixture(t);
  const root = await install(join(home, 'DevEco Studio'), true);
  const result = run({ ...env, DEVECO_HOME: root, DEVECO_CLI_CLT_PATH: join(home, 'unused') }, root);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
});

test('复用 DevEco CLI 的 CLT 路径并保留 SDK 覆盖', async t => {
  const { home, env } = await fixture(t);
  const root = await install(join(home, 'CLI tools'));
  const sdk = join(home, 'custom sdk');
  const result = run({ ...env, DEVECO_CLI_CLT_PATH: root, DEVECO_SDK_HOME: sdk, OHOS_SDK: join(home, 'custom ndk') }, root);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
});

test('多个本机 CLT 安装时要求显式选择而不是悄悄换 SDK', async t => {
  const { home, env } = await fixture(t);
  for (const version of ['26.0.0.865', '27.0.0.100']) {
    await install(join(home, `.local/opt/harmonyos-clt-${version}/command-line-tools`));
  }
  const result = run(env, home);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /HARMONYOS_TOOLS_HOME/);
});
