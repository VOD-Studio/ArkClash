import assert from 'node:assert/strict';
import { mkdtemp, copyFile, cp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test, { before, after } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const goVersion = (await readFile(join(root, '.go-version'), 'utf8')).trim();
const race = process.env.CORE_RACE === '1';
const goEnv = { ...process.env, CGO_ENABLED: '1', GOTOOLCHAIN: `go${goVersion}` };
const sandbox = await mkdtemp(join(tmpdir(), 'arkclash-core-host-'));
const executable = join(sandbox, 'core.test');
const linuxFdEnabled = process.platform === 'linux' || process.env.CORE_LINUX_FD === '1';
const linuxFdExecutable = join(sandbox, 'tun-fd.test');
const mihomoExecutables = ['dns', 'tunnel/statistic', 'adapter/inbound', 'listener/auth', 'log'].map((pkg, index) => ({
  pkg, executable: join(sandbox, `mihomo-${index}.test`)
}));
after(() => rm(sandbox, { recursive: true, force: true }));

// 冷缓存的工具链、依赖下载和编译不占用用例执行时限。
before(async () => {
  for (const file of ['go.mod', 'go.sum', 'lifecycle.go', 'inbound.go', 'runtime.go', 'selection.go', 'delay.go', 'probe.go', 'probe_body.go', 'proxies.go',
    'geo_settings.go', 'geo.go', 'geo_download.go', 'geo_events.go', 'diagnostics.go', 'dns_overrides.go',
    'added_rules.go', 'rule_set_data.go', 'rule_sets.go', 'profile_settings.go', 'profile_scripts.go', 'local_proxies.go', 'local_proxy_links.go',
    'proxy_filters.go', 'diagnostics_connections.go', 'diagnostics_dns.go', 'diagnostics_stream.go',
    'diagnostics_logs.go', 'general_settings.go', 'panel_controller.go', 'backup.go']) {
    await copyFile(join(root, 'core', file), join(sandbox, file));
  }
  for (const file of ['backup-live-host_test.go', 'core-host_test.go', 'delay-host_test.go', 'probe-host_test.go', 'proxies-host_test.go',
    'geo-reader-host_test.go', 'geo-host_test.go', 'geo-scheduler-host_test.go', 'diagnostics-host_test.go',
    'diagnostics-stream-host_test.go', 'diagnostics-lifecycle-host_test.go', 'diagnostics-control-host_test.go',
    'lifecycle-host_test.go', 'runtime-lifecycle-host_test.go', 'disconnected-delay-host_test.go', 'inbound-host_test.go',
    'controller-lifecycle-host_test.go', 'forwarding-lifecycle-host_test.go', 'dns-overrides-host_test.go',
    'added-rules-host_test.go', 'proxy-filters-host_test.go', 'rule-sets-host_test.go', 'profile-scripts-host_test.go', 'local-proxies-host_test.go', 'general-settings-host_test.go']) {
    await copyFile(new URL(`./${file}`, import.meta.url), join(sandbox, file));
  }
  await cp(join(root, 'core/internal'), join(sandbox, 'internal'), { recursive: true });
  const quickjs = spawnSync('bash', [join(root, 'scripts/prepare-quickjs.sh')], { encoding: 'utf8', timeout: 120000 });
  assert.equal(quickjs.status, 0, quickjs.stderr);
  goEnv.CGO_CPPFLAGS = `${process.env.CGO_CPPFLAGS ?? ''} -I ${JSON.stringify(quickjs.stdout.trim())}`;
  await cp(join(root, 'scripts/testdata/geo'), join(sandbox, 'testdata/geo'), { recursive: true });
  const prepare = spawnSync('bash', [join(root, 'scripts/prepare-mihomo.sh'), join(sandbox, 'mihomo')], {
    encoding: 'utf8', timeout: 300000, env: goEnv
  });
  assert.equal(prepare.status, 0, `${prepare.error ?? ''}\n${prepare.stdout}\n${prepare.stderr}`);
  for (const [source, destination] of [
    ['observation-dns-host_test.go', 'dns/arkclash_observation_test.go'],
    ['observation-clear-host_test.go', 'dns/arkclash_observation_clear_test.go'],
    ['observation-statistic-host_test.go', 'tunnel/statistic/arkclash_observation_test.go'],
    ['tun-fd-linux-host_test.go', 'listener/sing_tun/arkclash_fd_linux_test.go']
  ]) {
    await copyFile(join(root, 'scripts', source), join(sandbox, 'mihomo', destination));
  }
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
  const frameFunctions = ['upgradeWebSocket', 'writeTextFrame', 'getStatus'].map(name => {
    const declaration = apiSource.match(new RegExp(`^func ${name}\\([^\\n]+\\) [^\\n]*\\{[\\s\\S]*?^\\}`, 'm'))?.[0];
    assert.ok(declaration, `未找到产品 WebSocket/状态函数 ${name}`);
    return declaration;
  });
  await writeFile(join(sandbox, 'frames.go'), 'package main\nimport (\n' +
    '"bufio"\n"crypto/sha1"\n"encoding/base64"\n"encoding/binary"\n"errors"\n"io"\n"net"\n' +
    '"github.com/metacubex/http"\n"github.com/metacubex/chi/render"\n)\n' + frameFunctions.join('\n\n') + '\n');
  const build = spawnSync('go', ['test', '-mod=readonly', ...(race ? ['-race'] : []), '-c', '-o', executable, '.'], {
    cwd: sandbox, encoding: 'utf8', timeout: 600000, env: goEnv
  });
  assert.equal(build.status, 0, `${build.error ?? ''}\n${build.stdout}\n${build.stderr}`);
  for (const target of mihomoExecutables) {
    const compiled = spawnSync('go', ['test', '-mod=readonly', ...(race ? ['-race'] : []),
      '-c', '-o', target.executable, `github.com/metacubex/mihomo/${target.pkg}`], {
      cwd: sandbox, encoding: 'utf8', timeout: 600000, env: goEnv
    });
    assert.equal(compiled.status, 0, `${compiled.error ?? ''}\n${compiled.stdout}\n${compiled.stderr}`);
  }
  if (linuxFdEnabled) {
    const compiled = spawnSync('go', ['test', '-mod=readonly', '-c', '-o', linuxFdExecutable,
      'github.com/metacubex/mihomo/listener/sing_tun'], {
      cwd: sandbox, encoding: 'utf8', timeout: 600000,
      env: { ...goEnv, CGO_ENABLED: '0', GOOS: 'linux', GOARCH: process.arch === 'arm64' ? 'arm64' : 'amd64' }
    });
    assert.equal(compiled.status, 0, `${compiled.error ?? ''}\n${compiled.stdout}\n${compiled.stderr}`);
  }
}, { timeout: 900000 });

test('ZIP 备份、原子恢复和 WebDAV', { timeout: 90000 }, () => {
  const result = spawnSync('go', ['test', '-mod=readonly', '-count=1', '-v', './internal/backup'], {
    cwd: sandbox, encoding: 'utf8', timeout: 85000, env: goEnv
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

test('QuickJS 配置脚本与执行限额', { timeout: 90000 }, () => {
  const result = spawnSync('go', ['test', '-mod=readonly', '-count=1', '-v', './internal/script'], {
    cwd: sandbox, encoding: 'utf8', timeout: 85000, env: goEnv
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

// 原生 TUN 生命周期由宿主夹具提供；脚本执行使用与手机相同的 QuickJS 源码。
test('核心选择持久化、回滚、规则探测与实际请求取消', { timeout: 240000 }, () => {
  const result = spawnSync(executable, ['-test.count=1', '-test.timeout=90s', '-test.v',
    ...(process.env.CORE_TEST_RUN ? [`-test.run=${process.env.CORE_TEST_RUN}`] : [])], {
    cwd: sandbox, encoding: 'utf8', timeout: 230000, env: goEnv
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

test('mihomo 诊断、DNS 缓存与监听所有权回归', { timeout: 300000 }, () => {
  for (const target of mihomoExecutables) {
    const result = spawnSync(target.executable, ['-test.run=^TestArkClash', '-test.count=1',
      '-test.timeout=45s', '-test.v'], {
      cwd: sandbox, encoding: 'utf8', timeout: 55000, env: goEnv
    });
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    console.log(result.stdout.trim());
  }
});

test('Linux TUN 原始 fd 与副本所有权', { skip: !linuxFdEnabled, timeout: 120000 }, () => {
  const args = ['-test.run=^TestArkClash', '-test.count=1', '-test.timeout=45s', '-test.v'];
  const result = process.platform === 'linux' ?
    spawnSync(linuxFdExecutable, args, { encoding: 'utf8', timeout: 55000 }) :
    spawnSync('docker', ['run', '--rm', '--network', 'none', '--mount',
      `type=bind,source=${sandbox},target=/test,readonly`, process.env.CORE_LINUX_IMAGE ?? 'alpine:latest',
      '/test/tun-fd.test', ...args], { encoding: 'utf8', timeout: 110000 });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});
