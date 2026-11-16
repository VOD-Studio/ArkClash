import assert from 'node:assert/strict';
import { mkdtemp, copyFile, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test, { before, after } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const goVersion = (await readFile(join(root, '.go-version'), 'utf8')).trim();
const goEnv = { ...process.env, CGO_ENABLED: '0', GOTOOLCHAIN: `go${goVersion}` };
const sandbox = await mkdtemp(join(tmpdir(), 'arkclash-core-host-'));
const executable = join(sandbox, 'core.test');
after(() => rm(sandbox, { recursive: true, force: true }));

// 冷缓存的工具链、依赖下载和编译不占用用例执行时限。
before(async () => {
  for (const file of ['go.mod', 'go.sum', 'runtime.go', 'selection.go', 'delay.go', 'probe.go', 'probe_body.go', 'proxies.go']) {
    await copyFile(join(root, 'core', file), join(sandbox, file));
  }
  for (const file of ['core-host_test.go', 'delay-host_test.go', 'probe-host_test.go', 'proxies-host_test.go']) {
    await copyFile(new URL(`./${file}`, import.meta.url), join(sandbox, file));
  }
  const prepare = spawnSync('bash', [join(root, 'scripts/prepare-mihomo.sh'), join(sandbox, 'mihomo')], {
    encoding: 'utf8', timeout: 300000, env: goEnv
  });
  assert.equal(prepare.status, 0, `${prepare.error ?? ''}\n${prepare.stdout}\n${prepare.stderr}`);
  await writeFile(join(sandbox, 'go.mod'), await readFile(join(sandbox, 'go.mod'), 'utf8') +
    `\nreplace github.com/metacubex/mihomo => ${JSON.stringify(join(sandbox, 'mihomo'))}\n`);
  const apiSource = await readFile(join(root, 'core/api.go'), 'utf8');
  const fetchDeclarations = ['fetchRequest', 'fetchResult'].map(name => {
    const declaration = apiSource.match(new RegExp(`^type ${name} struct \\{[\\s\\S]*?^\\}`, 'm'))?.[0];
    assert.ok(declaration, `未找到产品下载类型 ${name}`);
    return declaration;
  });
  const fetchFunctions = ['fetch', 'writeBody'].map(name => {
    const declaration = apiSource.match(new RegExp(`^func ${name}\\([^\\n]+\\) [^\\n]+ \\{[\\s\\S]*?^\\}`, 'm'))?.[0];
    assert.ok(declaration, `未找到产品下载函数 ${name}`);
    return declaration;
  });
  const fetchLimit = apiSource.match(/^const fetchLimit = .+$/m)?.[0];
  assert.ok(fetchLimit, '未找到产品下载上限');
  await writeFile(join(sandbox, 'fetch.go'), 'package main\nimport (\n' +
    '"context"\n"errors"\n"io"\n"net/url"\n"os"\n"strings"\n"time"\n' +
    '"github.com/metacubex/http"\n)\n' + [fetchLimit, ...fetchDeclarations, ...fetchFunctions].join('\n\n') + '\n');
  const nativeSource = await readFile(join(root, 'core/lib.go'), 'utf8');
  const lifecycle = ['checkProfilePath', 'runningProfile'].map(name => {
    const declaration = nativeSource.match(new RegExp(`^func ${name}\\([^\\n]*\\) [^\\n]+ \\{[\\s\\S]*?^\\}`, 'm'))?.[0];
    assert.ok(declaration, `未找到产品生命周期函数 ${name}`);
    return declaration;
  }).join('\n\n');
  const options = nativeSource.match(/^type startOptions struct \{[\s\S]*?^\}/m)?.[0];
  const overrides = nativeSource.match(/^func applyOverrides\([^\n]+\) \{[\s\S]*?^\}/m)?.[0];
  assert.ok(options && overrides, '未找到产品配置覆盖接缝');
  await writeFile(join(sandbox, 'overrides.go'), `package main\nimport (\n"strings"\n"fmt"\n"path/filepath"\n` +
    `"github.com/metacubex/mihomo/component/process"\n"github.com/metacubex/mihomo/config"\n` +
    `"github.com/metacubex/mihomo/constant"\n"github.com/metacubex/mihomo/tunnel"\n)\n${options}\n${overrides}\n${lifecycle}\n`);
  const build = spawnSync('go', ['test', '-mod=readonly', '-c', '-o', executable, '.'], {
    cwd: sandbox, encoding: 'utf8', timeout: 600000, env: goEnv
  });
  assert.equal(build.status, 0, `${build.error ?? ''}\n${build.stdout}\n${build.stderr}`);
}, { timeout: 900000 });

// 编译产品的纯 Go 控制层，原生 TUN 生命周期由宿主夹具提供；不加载手机共享库。
test('核心选择持久化、回滚、规则探测与实际请求取消', { timeout: 240000 }, () => {
  const result = spawnSync(executable, ['-test.count=1', '-test.timeout=90s', '-test.v'], {
    cwd: sandbox, encoding: 'utf8', timeout: 230000, env: goEnv
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});
