import assert from 'node:assert/strict';
import { mkdtemp, copyFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test, { before, after } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const coreDir = join(root, 'core');
const goVersion = (await readFile(join(root, '.go-version'), 'utf8')).trim();
const race = process.env.CORE_RACE === '1';
const raceFlag = race ? ['-race'] : [];
const goEnv = { ...process.env, CGO_ENABLED: '1', GOTOOLCHAIN: process.env.GOTOOLCHAIN ?? `go${goVersion}` };
const depsDir = await mkdtemp(join(tmpdir(), 'arkclash-core-host-'));
const modfile = join(depsDir, 'go.mod');
const linuxFdEnabled = process.env.CORE_LINUX_FD === '0'
  ? false
  : (process.platform === 'linux' || process.env.CORE_LINUX_FD === '1');
const linuxFdExecutable = join(depsDir, 'tun-fd.test');
const mihomoPackages = ['dns', 'tunnel/statistic', 'adapter/inbound', 'listener/auth', 'log', 'adapter/outbound'];
const maxBuffer = 16 * 1024 * 1024;
after(() => rm(depsDir, { recursive: true, force: true }));

function runGo(args, options = {}) {
  return spawnSync('go', args, {
    cwd: coreDir,
    encoding: 'utf8',
    maxBuffer,
    env: goEnv,
    ...options
  });
}

// 冷缓存的工具链、依赖下载和编译不占用用例执行时限；测试在 core/ 原地执行，不再拷贝业务源码。
before(async () => {
  const prepare = spawnSync('bash', [join(root, 'scripts/core/prepare-deps.sh'), depsDir], {
    encoding: 'utf8', timeout: 300000, maxBuffer, env: goEnv
  });
  assert.equal(prepare.status, 0, `${prepare.error ?? ''}\n${prepare.stdout}\n${prepare.stderr}`);
  goEnv.CGO_CPPFLAGS = `${process.env.CGO_CPPFLAGS ?? ''} -I ${JSON.stringify(join(depsDir, 'quickjs'))}`;

  for (const [source, destination] of [
    ['observation-dns-host_test.go', 'dns/arkclash_observation_test.go'],
    ['observation-clear-host_test.go', 'dns/arkclash_observation_clear_test.go'],
    ['observation-statistic-host_test.go', 'tunnel/statistic/arkclash_observation_test.go'],
    ['tun-fd-linux-host_test.go', 'listener/sing_tun/arkclash_fd_linux_test.go'],
    ['tailscale-address-host_test.go', 'adapter/outbound/arkclash_tailscale_address_test.go']
  ]) {
    await copyFile(join(root, 'scripts', source), join(depsDir, 'mihomo', destination));
  }

  // 预热编译缓存，不执行测试。
  const prewarm = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag, '-run=^$', './internal/...'], {
    timeout: 600000
  });
  assert.equal(prewarm.status, 0, `${prewarm.error ?? ''}\n${prewarm.stdout}\n${prewarm.stderr}`);

  for (const pkg of mihomoPackages) {
    const prewarmPkg = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag,
      ...(pkg === 'adapter/outbound' ? ['-tags', 'with_gvisor'] : []),
      '-run=^$', `github.com/metacubex/mihomo/${pkg}`], { timeout: 600000 });
    assert.equal(prewarmPkg.status, 0, `${prewarmPkg.error ?? ''}\n${prewarmPkg.stdout}\n${prewarmPkg.stderr}`);
  }

  if (linuxFdEnabled) {
    const compiled = process.platform === 'linux'
      ? runGo(['test', '-mod=readonly', '-modfile', modfile, '-run=^$', 'github.com/metacubex/mihomo/listener/sing_tun'], {
        timeout: 600000, env: { ...goEnv, CGO_ENABLED: '0' }
      })
      : runGo(['test', '-mod=readonly', '-modfile', modfile, '-c', '-o', linuxFdExecutable,
        'github.com/metacubex/mihomo/listener/sing_tun'], {
        timeout: 600000,
        env: { ...goEnv, CGO_ENABLED: '0', GOOS: 'linux', GOARCH: process.arch === 'arm64' ? 'arm64' : 'amd64' }
      });
    assert.equal(compiled.status, 0, `${compiled.error ?? ''}\n${compiled.stdout}\n${compiled.stderr}`);
  }
}, { timeout: 900000 });

test('ZIP 备份、原子恢复和 WebDAV', { timeout: 90000 }, () => {
  const result = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag, '-count=1', '-v', './internal/backup'], {
    timeout: 85000
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

test('QuickJS 配置脚本与执行限额', { timeout: 90000 }, () => {
  const result = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag, '-count=1', '-v', './internal/script'], {
    timeout: 85000
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

test('内部纯引擎与独立子系统', { timeout: 90000 }, () => {
  const listed = runGo(['list', '-mod=readonly', '-modfile', modfile, './internal/...'], { timeout: 30000 });
  assert.equal(listed.status, 0, `${listed.error ?? ''}\n${listed.stdout}\n${listed.stderr}`);
  const pkgs = listed.stdout.split(/\r?\n/).map(line => line.trim())
    .filter(pkg => pkg &&
      !pkg.endsWith('/internal/backup') &&
      !pkg.endsWith('/internal/script') &&
      !pkg.endsWith('/internal/engine') &&
      !pkg.endsWith('/internal/api'));
  if (pkgs.length === 0) {
    return;
  }
  const result = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag, '-count=1', '-v', ...pkgs], {
    timeout: 85000
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

// 宿主只替换 TUN 构造器；核心引擎与控制面路由在 core/internal/{engine,api} 原地编译执行。
test('核心引擎与控制面选择持久化、回滚、规则探测与取消', { timeout: 240000 }, () => {
  const result = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag, '-count=1', '-timeout=90s', '-v',
    ...(process.env.CORE_TEST_RUN ? [`-run=${process.env.CORE_TEST_RUN}`] : []),
    ...(process.env.CORE_TEST_SKIP ? [`-skip=${process.env.CORE_TEST_SKIP}`] : []),
    './internal/engine', './internal/api'], {
    timeout: 230000
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});

test('mihomo 诊断、DNS 缓存、监听所有权与 Tailscale 拨号回归', { timeout: 300000 }, () => {
  for (const pkg of mihomoPackages) {
    const result = runGo(['test', '-mod=readonly', '-modfile', modfile, ...raceFlag,
      ...(pkg === 'adapter/outbound' ? ['-tags', 'with_gvisor'] : []),
      '-run=^TestArkClash', '-count=1', '-timeout=45s', '-v', `github.com/metacubex/mihomo/${pkg}`], {
      timeout: 55000
    });
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    console.log(result.stdout.trim());
  }
});

test('Linux TUN 原始 fd 与副本所有权', { skip: !linuxFdEnabled, timeout: 120000 }, () => {
  const result = process.platform === 'linux'
    ? runGo(['test', '-mod=readonly', '-modfile', modfile, '-run=^TestArkClash', '-count=1', '-timeout=45s', '-v',
      'github.com/metacubex/mihomo/listener/sing_tun'], {
      timeout: 55000, env: { ...goEnv, CGO_ENABLED: '0' }
    })
    : spawnSync('docker', ['run', '--rm', '--network', 'none', '--mount',
      `type=bind,source=${depsDir},target=/test,readonly`, process.env.CORE_LINUX_IMAGE ?? 'alpine:latest',
      '/test/tun-fd.test', '-test.run=^TestArkClash', '-test.count=1', '-test.timeout=45s', '-test.v'], {
      encoding: 'utf8', maxBuffer, timeout: 110000
    });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  console.log(result.stdout.trim());
});
