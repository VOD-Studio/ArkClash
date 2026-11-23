import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const compiled = new Map();
const root = new URL('../entry/src/main/ets/', import.meta.url);
const filesDir = '/vpn-lifecycle-fixture';
const runtimePath = `${filesDir}/runtime.json`;
const instancePath = `${filesDir}/runtime-instance.json`;
const stoppedPath = `${filesDir}/runtime-stopped.json`;

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function fixture(t, { empty = false, historicalIntent = 'stopped' } = {}) {
  const files = new Map();
  const calls = [];
  const failures = new Map();
  const holds = new Map();
  const gates = [];
  const pendingReplies = new Map();
  const timers = new Map();
  let nextFd = 100;
  let nextTimer = 1;
  let nextCommand = 1;
  let commandCallback;
  let registrations = 0;
  let platformCreated = false;
  let activeTun = false;
  let listenersOpen = false;
  let running = false;
  let randomSequence = 0;
  let status = { profile: '', bootId: 'fixture.boot', configRevision: 1, revision: 0,
    intent: 'stopped', forward: 'stopped', vpnCreated: false, startedAt: 0, mode: 'rule' };
  const schedulers = [];
  const json = (path, value) => files.set(path, JSON.stringify(value));
  json(runtimePath, { secret: 'fixture.secret', stack: 'gvisor', mode: 'rule',
    vpnIntent: historicalIntent, vpnOperation: 'historical-operation' });
  json(`${filesDir}/profiles/list.json`, { version: 1, current: empty ? '' : 'fixture', subscriptions: [],
    profiles: empty ? [] : [{ id: 'fixture', name: 'Fixture', nameEdited: false, subscription: '' }] });
  if (!empty) files.set(`${filesDir}/profiles/fixture.yaml`, 'proxies: []');

  async function invoke(name, args = []) {
    calls.push({ name, args });
    const gate = holds.get(name);
    if (gate !== undefined) {
      holds.delete(name);
      gate.entered.resolve(args);
      await gate.release.promise;
    }
    const queue = failures.get(name);
    if (queue?.length) throw queue.shift();
  }
  const snapshot = () => ({ ...status, running, tunAttached: activeTun, listenersOpen,
    sessionMode: 'tun', version: 'fixture' });
  const native = {
    async start(options) {
      await invoke('start', [JSON.parse(options)]);
      running = true;
      status = { ...status, profile: JSON.parse(options).profile, revision: status.revision + 1 };
    },
    async stop() {
      await invoke('stop');
      running = false;
      activeTun = false;
      listenersOpen = false;
    },
    async attachTun(fd, optionsJson, bootId, profile, configRevision) {
      await invoke('attachTun', [fd, JSON.parse(optionsJson), bootId, profile, configRevision]);
      if (bootId !== status.bootId || profile !== status.profile || configRevision !== status.configRevision) {
        throw new Error('stale_attach_identity');
      }
      assert.ok(platformCreated, 'native attachment must follow successful platform creation');
      assert.equal(fd, 73);
      activeTun = true;
      listenersOpen = true;
    },
    async detachTun() {
      await invoke('detachTun');
      activeTun = false;
      listenersOpen = false;
    },
    async updateVpnState(intent, forward, vpnCreated) {
      await invoke('updateVpnState', [intent, forward, vpnCreated]);
      status = { ...status, intent, forward, vpnCreated, revision: status.revision + 1,
        startedAt: forward === 'running' ? 1000 : 0 };
    },
    async runtimeStatus() { await invoke('runtimeStatus'); return JSON.stringify(snapshot()); },
    runningProfile() { return running ? status.profile : ''; },
    async reload(path, profile, expectedProfile) {
      await invoke('reload', [path, profile, expectedProfile]);
      status = { ...status, profile, configRevision: status.configRevision + 1 };
    },
    async prefetch(path) { await invoke('prefetch', [path]); return 'ready'; },
    onCommand(callback) { registrations++; commandCallback = callback; },
    reply(id, code, body) {
      const result = { status: code, body: JSON.parse(body) };
      calls.push({ name: 'reply', args: [id, code] });
      pendingReplies.get(id)?.resolve(result);
      pendingReplies.delete(id);
    },
    emit(body) { calls.push({ name: 'emit', args: [JSON.parse(body)] }); }
  };
  const connection = {
    async protectProcessNet() { await invoke('protectProcessNet'); },
    async create(config) {
      await invoke('create', [config]);
      assert.equal(platformCreated, false, 'a second platform VPN must not be created');
      platformCreated = true;
      return 73;
    },
    async destroy() { await invoke('destroy'); platformCreated = false; }
  };
  class Scheduler {
    constructor(env, updated) { this.env = env; this.updated = updated; this.generation = 0; this.running = false;
      this.reschedules = 0; schedulers.push(this); }
    start() { calls.push({ name: 'scheduler.start', args: [] }); this.running = true; }
    stop(abort) { calls.push({ name: 'scheduler.stop', args: [abort] }); this.running = false;
      if (abort) this.generation++; }
    operationGeneration() { return this.generation; }
    acceptsGeneration(generation) { return generation === this.generation; }
    reschedule() { this.reschedules++; }
    async update(subscription, url) {
      await invoke('scheduler.update', [subscription, url]);
      return { subscription, ok: true, state: { updatedAt: 1, failures: 0 } };
    }
  }

  const openFiles = new Map();
  const missing = () => Object.assign(new Error('fixture file missing'), { code: 13900002 });
  const read = path => { if (!files.has(path)) throw missing(); return files.get(path); };
  const open = path => {
    const file = { fd: nextFd++, async lock() {}, tryLock() {} };
    openFiles.set(file.fd, path);
    if (!files.has(path)) files.set(path, '');
    return file;
  };
  const write = (fd, text) => {
    const value = typeof text === 'string' ? text : Buffer.from(text).toString('utf8');
    assert.ok(openFiles.has(fd), 'write requires an open fixture file');
    files.set(openFiles.get(fd), value);
    return Buffer.byteLength(value);
  };
  const rename = (from, to) => { files.set(to, read(from)); files.delete(from); };
  const fs = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_WRITE: 8 },
    accessSync: path => files.has(path), async access(path) { return files.has(path); },
    readTextSync: read, async readText(path) { return read(path); },
    async stat(path) { return { size: Buffer.byteLength(read(path)) }; },
    openSync: open, async open(path) { return open(path); },
    writeSync: write, async write(fd, text) { return write(fd, text); },
    closeSync: file => openFiles.delete(file.fd), async close(file) { openFiles.delete(file.fd); },
    renameSync: rename, async rename(from, to) { rename(from, to); },
    async unlink(path) { if (!files.delete(path)) throw missing(); },
    mkdirSync() {}, async mkdir() {}, async fsync() {}
  };
  const context = { filesDir, applicationInfo: { name: 'fixture.application' } };
  const bindings = new Map([
    ['@kit.AbilityKit', { appManager: {} }],
    ['@kit.BasicServicesKit', {}],
    ['@kit.ArkTS', { process: { pid: 20 },
      util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } }, url: { URL },
      taskpool: { execute: async (operation, ...args) => operation(...args) } }],
    ['@kit.CoreFileKit', { fileIo: fs }],
    ['@kit.PerformanceAnalysisKit', { hilog: { info() {}, error() {}, warn() {} } }],
    ['@kit.NetworkKit', { VpnExtensionAbility: class { constructor() { this.context = context; } },
      vpnExtension: {
        createVpnConnection() { calls.push({ name: 'createVpnConnection', args: [] }); return connection; },
        async stopVpnExtensionAbility() { await invoke('stopVpnExtensionAbility'); }
      } }],
    ['libarkclash.so', { default: native }],
    [new URL('shared/profiles/Updater.ets', root).href, { UpdateScheduler: Scheduler,
      async downloadNewSubscription() { throw new Error('unexpected subscription download'); } }],
    [new URL('vpn/GeoData.ets', root).href, { async installGeoData() { await invoke('installGeoData'); } }],
    [new URL('vpn/KernelDownloader.ets', root).href, { KernelDownloader: class {
      async download(source, path, identity) {
        await invoke('downloadIconSet', [source, identity.maxBytes]);
        json(path, { name: 'Fixture icons', icons: [{ url: 'https://example.test/Proxy.svg' }] });
      }
    } }]
  ]);
  const modules = new Map();
  class Clock extends Date { static now() { return 1000; } }
  const deterministicMath = Object.create(Math);
  deterministicMath.random = () => ++randomSequence / 100000;
  const globals = {
    Promise, Error, JSON, Number, Math: deterministicMath, Set, Map, Date: Clock, Uint8Array, TextEncoder,
    setTimeout(callback, milliseconds) { const id = nextTimer++; timers.set(id, { callback, milliseconds }); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  function load(file) {
    if (bindings.has(file.href)) return bindings.get(file.href);
    if (modules.has(file.href)) return modules.get(file.href).exports;
    if (!compiled.has(file.href)) {
      compiled.set(file.href, ts.transpileModule(readFileSync(file, 'utf8'), {
        fileName: file.pathname.replace(/\.ets$/, '.ts'),
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
      }).outputText);
    }
    const module = { exports: {} };
    modules.set(file.href, module);
    vm.runInNewContext(compiled.get(file.href), { ...globals, module, exports: module.exports,
      require(name) {
        if (bindings.has(name)) return bindings.get(name);
        assert.ok(name.startsWith('.'), `unexpected extension dependency ${name}`);
        return load(new URL(`${name}.ets`, file));
      }
    }, { filename: file.pathname });
    return module.exports;
  }
  const Ability = load(new URL('vpn/ClashVpnAbility.ets', root)).default;
  const instance = new Ability();
  const runtime = () => JSON.parse(read(runtimePath));
  const api = {
    instance, calls, files, native, schedulers, snapshot,
    count: name => calls.filter(call => call.name === name).length,
    get registrations() { return registrations; },
    get platformCreated() { return platformCreated; },
    runtime,
    intent(intent, operationId) { json(runtimePath, { ...runtime(), vpnIntent: intent, vpnOperation: operationId }); },
    fail(name, message = `fixture ${name} failure`) {
      if (!failures.has(name)) failures.set(name, []);
      failures.get(name).push(new Error(message));
    },
    hold(name) {
      assert.equal(holds.has(name), false, `duplicate fixture gate ${name}`);
      const gate = { entered: deferred(), release: deferred() };
      gates.push(gate);
      holds.set(name, gate);
      return { entered: gate.entered.promise, release: () => gate.release.resolve() };
    },
    mutateStatus(change) { status = { ...status, ...change }; },
    replaceRuntime(change) { json(runtimePath, { ...runtime(), ...change }); },
    replaceInstance(value) { json(instancePath, value); },
    receipt() { return files.has(stoppedPath) ? JSON.parse(read(stoppedPath)) : undefined; },
    activeInstance() { return JSON.parse(read(instancePath)); },
    async warm() { instance.onCreate({}); await instance.startup; },
    async shutdown() { instance.onDestroy(); assert.ok(instance.cleanupPending); await instance.cleanupPending; },
    command(name, body) {
      assert.equal(typeof commandCallback, 'function', 'extension must install its native command handler');
      const id = nextCommand++;
      const result = deferred();
      pendingReplies.set(id, result);
      commandCallback(id, name, JSON.stringify(body));
      return { id, result: result.promise, detach() { pendingReplies.delete(id); } };
    },
    request(kind, operationId, overrides = {}, writeIntent = true) {
      if (writeIntent) api.intent(kind === 'connect' ? 'started' : 'stopped', operationId);
      const current = snapshot();
      return api.command(`vpn/${kind}`, { bootId: current.bootId, operationId,
        ...(kind === 'connect' ? { profile: current.profile, configRevision: current.configRevision } : {}), ...overrides });
    }
  };
  t.after(async () => {
    failures.clear();
    for (const gate of gates) gate.release.resolve();
    instance.onDestroy();
    await instance.cleanupPending;
  });
  return api;
}

function assertWarm(f) {
  const status = f.snapshot();
  assert.equal(status.running, true);
  assert.equal(status.intent, 'stopped');
  assert.equal(status.forward, 'stopped');
  assert.equal(status.vpnCreated, false);
  assert.equal(status.tunAttached, false);
  assert.equal(status.listenersOpen, false);
  assert.equal(f.platformCreated, false);
}

function assertConnected(f) {
  const status = f.snapshot();
  assert.equal(status.running, true);
  assert.equal(status.intent, 'started');
  assert.equal(status.forward, 'running');
  assert.equal(status.vpnCreated, true);
  assert.equal(status.tunAttached, true);
  assert.equal(f.platformCreated, true);
}

async function connect(f, operation = 'connect-1') {
  const reply = await f.request('connect', operation).result;
  assert.equal(reply.status, 200);
  assertConnected(f);
  assert.equal(reply.body.bootId, f.snapshot().bootId);
  assert.equal(reply.body.configRevision, f.snapshot().configRevision);
  assert.equal(reply.body.vpnCreated, true);
  assert.equal(reply.body.tunAttached, true);
  return reply;
}

// 每个用例独立装载真实扩展和命令模块；平台资源与原生事实由受控边界提供。
test('VPN宿主预热不创建系统VPN，历史连接意图也不自动接管', async t => {
  const f = fixture(t, { historicalIntent: 'started' });
  await f.warm();
  assertWarm(f);
  assert.equal(f.count('create'), 0);
  assert.equal(f.count('attachTun'), 0);
  assert.equal(f.count('start'), 1);
  assert.equal(f.count('protectProcessNet'), 1);
  assert.equal(f.schedulers[0].running, true);
  assert.equal(f.receipt(), undefined);
  const options = f.calls.find(call => call.name === 'start').args[0];
  assert.equal(options.profile, 'fixture');
  assert.equal('tunFd' in options, false);
});

test('空配置可以预热，但不能创建系统VPN', async t => {
  const f = fixture(t, { empty: true });
  await f.warm();
  assertWarm(f);
  assert.equal(f.snapshot().profile, '');
  assert.equal(f.calls.find(call => call.name === 'start').args[0].configPath, '');
  const reply = await f.request('connect', 'empty-connect').result;
  assert.notEqual(reply.status, 200);
  assert.equal(f.count('create'), 0);
  assert.equal(f.count('attachTun'), 0);
});

test('VPN 将同一份网络设置用于系统接口和内核，旧配置保留原有默认值', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  const initial = f.calls.find(call => call.name === 'create').args[0];
  assert.equal(initial.mtu, 1500);
  assert.equal(initial.isIPv6Accepted, false);
  assert.equal(initial.routes.length, 1);
  assert.equal(initial.routes[0].destination.address.address, '0.0.0.0');
  assert.deepEqual(Array.from(initial.blockedApplications), ['fixture.application']);
  assert.equal(f.calls.find(call => call.name === 'attachTun').args[1].dnsHijacking, true);
  assert.equal((await f.request('disconnect', 'disconnect-advanced').result).status, 200);

  f.replaceRuntime({ network: {
    stack: 'mips', mtu: 1400, ipv6: true, dnsHijacking: false, congestionController: 'bbr',
    bypassPrivateRoute: true, routeAddress: ['192.0.2.0/24', '2001:db8::/32'],
    routeExcludeAddress: ['192.0.2.0/25', '2001:db8::/33'],
    excludedApplications: ['com.example.direct', 'fixture.application', 'com.example.direct', 'com.example.reader']
  } });
  assert.equal((await f.request('connect', 'connect-advanced').result).status, 200);
  const config = f.calls.filter(call => call.name === 'create').at(-1).args[0];
  const core = f.calls.filter(call => call.name === 'attachTun').at(-1).args[1];
  assert.equal(config.isIPv6Accepted, true);
  assert.equal(config.addresses[1].address.family, 2);
  assert.ok(config.dnsAddresses.includes('fdfe:dcba:9876::2'));
  assert.deepEqual(Array.from(config.blockedApplications),
    ['fixture.application', 'com.example.direct', 'com.example.reader']);
  assert.equal(config.mtu, 1400);
  assert.equal(core.mtu, config.mtu);
  assert.equal(core.ipv6, config.isIPv6Accepted);
  assert.equal(core.stack, 'mips');
  assert.equal(core.congestionController, 'bbr');
  assert.equal(core.dnsHijacking, false);
  assert.deepEqual(Array.from(config.routes, route => [
    route.destination.address.address, route.destination.prefixLength
  ]), [
    ['192.0.2.128', 25], ['172.19.0.2', 32], ['2001:db8:8000:0:0:0:0:0', 33],
    ['fdfe:dcba:9876:0:0:0:0:2', 128]
  ]);
});

test('重复连接和断开幂等，保留同一个核心、配置与更新调度器', async t => {
  const f = fixture(t);
  await f.warm();
  const identity = f.snapshot();
  await connect(f);
  assert.equal((await f.request('connect', 'connect-1').result).status, 200);
  assert.equal((await f.request('connect', 'connect-2').result).status, 200);
  assert.equal(f.count('create'), 1);
  assert.equal(f.count('attachTun'), 1);
  assert.equal((await f.request('disconnect', 'disconnect-1').result).status, 200);
  const detached = { detach: f.count('detachTun'), destroy: f.count('destroy') };
  assert.equal((await f.request('disconnect', 'disconnect-1').result).status, 200);
  assert.equal((await f.request('disconnect', 'disconnect-2').result).status, 200);
  assert.equal(f.count('detachTun'), detached.detach);
  assert.equal(f.count('destroy'), detached.destroy);
  assertWarm(f);
  assert.equal(f.snapshot().bootId, identity.bootId);
  assert.equal(f.snapshot().configRevision, identity.configRevision);
  assert.equal(f.count('start'), 1);
  assert.equal(f.count('stop'), 0);
  assert.equal(f.count('scheduler.stop'), 0);
  assert.equal(f.schedulers[0].running, true);
  assert.equal(f.receipt(), undefined);
  await connect(f, 'reconnect');
  assert.equal(f.count('createVpnConnection'), 1);
  assert.equal(f.snapshot().bootId, identity.bootId);
});

test('平台create拒绝且清理成功后撤销启动意图，可直接重试', async t => {
  const f = fixture(t);
  await f.warm();
  f.fail('create');
  const reply = await f.request('connect', 'failed-create').result;
  assert.equal(reply.status, 500);
  assert.equal(reply.body.message, 'vpn_create_failed');
  assert.equal(f.count('attachTun'), 0);
  assert.equal(f.platformCreated, false);
  assertWarm(f);
  assert.equal(f.runtime().vpnIntent, 'stopped');
  assert.equal(f.runtime().vpnOperation, 'failed-create');
  assert.equal(f.count('stop'), 0);
  assert.equal(f.receipt(), undefined);
  await connect(f, 'retry-create');
});

test('create和destroy失败时保留重试停止，直到平台确认清理', async t => {
  const f = fixture(t);
  await f.warm();
  f.fail('create');
  f.fail('destroy');
  const reply = await f.request('connect', 'failed-create-and-cleanup').result;
  assert.equal(reply.status, 500);
  assert.equal(reply.body.message, 'vpn_create_failed;vpn_destroy_failed');
  assert.equal(f.runtime().vpnIntent, 'started');
  assert.equal(f.snapshot().forward, 'failed');
  assert.equal(f.snapshot().vpnCreated, false);
  assert.equal((await f.request('disconnect', 'retry-cleanup').result).status, 200);
  assertWarm(f);
  await connect(f, 'retry-create');
});

test('连接失败回滚不覆盖清理期间写入的新启动意图', async t => {
  const f = fixture(t);
  await f.warm();
  f.fail('create');
  const cleanup = f.hold('destroy');
  const failing = f.request('connect', 'old-connect');
  await cleanup.entered;
  const retry = f.request('connect', 'new-connect');
  cleanup.release();
  assert.equal((await failing.result).status, 409);
  assert.equal((await retry.result).status, 200);
  assertConnected(f);
  assert.equal(f.runtime().vpnIntent, 'started');
  assert.equal(f.runtime().vpnOperation, 'new-connect');
});

for (const cleanupFailure of [undefined, 'detachTun', 'destroy']) {
  test(`attach失败独立尝试两条清理路径${cleanupFailure ? `，${cleanupFailure}失败可重试` : ''}`, async t => {
    const f = fixture(t);
    await f.warm();
    f.fail('attachTun');
    if (cleanupFailure) f.fail(cleanupFailure);
    assert.notEqual((await f.request('connect', 'failed-attach').result).status, 200);
    assert.ok(f.count('detachTun') >= 1);
    assert.equal(f.count('destroy'), 1);
    assert.equal(f.snapshot().running, true);
    assert.equal(f.snapshot().tunAttached, false);
    assert.notEqual(f.snapshot().forward, 'running');
    assert.equal(f.snapshot().vpnCreated, cleanupFailure === 'destroy');
    assert.equal(f.runtime().vpnIntent, cleanupFailure === undefined ? 'stopped' : 'started');
    assert.equal(f.platformCreated, cleanupFailure === 'destroy');
    assert.equal(f.count('stop'), 0);
    assert.equal(f.receipt(), undefined);
    assert.equal((await f.request('disconnect', 'retry-cleanup').result).status, 200);
    assertWarm(f);
  });
}

test('断开detach失败仍销毁平台VPN，残留TUN只有重试成功才清零', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  f.fail('detachTun');
  assert.notEqual((await f.request('disconnect', 'failed-detach').result).status, 200);
  assert.equal(f.count('destroy'), 1);
  assert.equal(f.platformCreated, false);
  assert.equal(f.snapshot().vpnCreated, false);
  assert.equal(f.snapshot().tunAttached, true);
  assert.notEqual(f.snapshot().forward, 'stopped');
  assert.equal(f.receipt(), undefined);
  assert.equal((await f.request('disconnect', 'retry-detach').result).status, 200);
  assertWarm(f);
  assert.equal(f.count('stop'), 0);
});

test('断开destroy失败保留系统VPN事实，重试后才报告停止', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  f.fail('destroy');
  assert.notEqual((await f.request('disconnect', 'disconnect-failed').result).status, 200);
  assert.equal(f.snapshot().tunAttached, false);
  assert.equal(f.snapshot().vpnCreated, true);
  assert.equal(f.platformCreated, true);
  assert.notEqual(f.snapshot().forward, 'stopped');
  assert.equal(f.receipt(), undefined);
  assert.equal((await f.request('disconnect', 'disconnect-retry').result).status, 200);
  assertWarm(f);
  assert.equal(f.count('destroy'), 2);
  assert.equal(f.count('stop'), 0);
});

test('onDestroy等待迟到create并释放资源，不附加TUN或提前写停止回执', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('create');
  const request = f.request('connect', 'connect-during-destroy');
  await gate.entered;
  f.instance.onDestroy();
  const cleanup = f.instance.cleanupPending;
  assert.ok(cleanup);
  assert.equal(f.receipt(), undefined);
  gate.release();
  assert.notEqual((await request.result).status, 200);
  await cleanup;
  assert.equal(f.count('attachTun'), 0);
  assert.equal(f.platformCreated, false);
  assert.equal(f.snapshot().running, false);
  assert.equal(f.snapshot().tunAttached, false);
  assert.deepEqual(f.receipt(), f.activeInstance());
  assert.equal(f.count('stop'), 1);
});

test('迟到connect不能越过已经写盘并完成的disconnect操作token', async t => {
  const f = fixture(t);
  await f.warm();
  f.intent('started', 'old-connect');
  assert.equal((await f.request('disconnect', 'new-disconnect').result).status, 200);
  const reply = await f.request('connect', 'old-connect', {}, false).result;
  assert.equal(reply.status, 409);
  assert.equal(f.count('create'), 0);
  assertWarm(f);
});

test('create等待期间token变更使旧连接回滚，串行断开完成后才能再次连接', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('create');
  const connecting = f.request('connect', 'old-connect');
  await gate.entered;
  const disconnecting = f.request('disconnect', 'new-disconnect');
  gate.release();
  assert.equal((await connecting.result).status, 409);
  assert.equal((await disconnecting.result).status, 200);
  assert.equal(f.count('attachTun'), 0);
  assert.equal(f.count('destroy'), 1);
  assertWarm(f);
  await connect(f, 'latest-connect');
  assert.equal(f.count('create'), 2);
});

test('attach等待期间token变更也会卸载迟到TUN并释放系统VPN', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('attachTun');
  const connecting = f.request('connect', 'old-connect');
  await gate.entered;
  const disconnecting = f.request('disconnect', 'new-disconnect');
  gate.release();
  assert.equal((await connecting.result).status, 409);
  assert.equal((await disconnecting.result).status, 200);
  assertWarm(f);
  assert.equal(f.count('attachTun'), 1);
  assert.ok(f.count('detachTun') >= 1);
  assert.equal(f.count('destroy'), 1);
});

test('陈旧boot不能断开当前VPN，当前boot断开不依赖旧配置revision', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  const before = { detach: f.count('detachTun'), destroy: f.count('destroy') };
  assert.equal((await f.request('disconnect', 'stale-disconnect', { bootId: 'old.boot' }).result).status, 409);
  assertConnected(f);
  assert.equal(f.count('detachTun'), before.detach);
  assert.equal(f.count('destroy'), before.destroy);
  f.mutateStatus({ configRevision: 2 });
  assert.equal((await f.request('disconnect', 'latest-disconnect', { configRevision: 1 }).result).status, 200);
  assertWarm(f);
  assert.equal(f.snapshot().configRevision, 2);
});

for (const stale of [{ bootId: 'old.boot' }, { profile: 'old-profile' }, { configRevision: 2 }]) {
  test(`陈旧连接身份${Object.keys(stale)[0]}返回409且不触碰平台资源`, async t => {
    const f = fixture(t);
    await f.warm();
    assert.equal((await f.request('connect', 'stale-connect', stale).result).status, 409);
    assert.equal(f.count('create'), 0);
    assert.equal(f.count('attachTun'), 0);
    assertWarm(f);
  });
}

test('创建期间配置换代由原子attach校验拒绝，并清理已创建系统VPN', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('create');
  const request = f.request('connect', 'stale-during-create');
  await gate.entered;
  f.mutateStatus({ configRevision: 2 });
  gate.release();
  assert.equal((await request.result).status, 409);
  assert.equal(f.snapshot().tunAttached, false);
  assert.equal(f.snapshot().vpnCreated, false);
  assert.equal(f.platformCreated, false);
  assert.equal(f.snapshot().configRevision, 2);
});

test('HTTP请求者超时离开不取消已经入队的转发操作', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('create');
  const request = f.request('connect', 'abandoned-http');
  await gate.entered;
  request.detach();
  const reported = f.hold('updateVpnState');
  gate.release();
  await reported.entered;
  reported.release();
  // 同一操作的重发只等待串行队列，不再次创建VPN。
  assert.equal((await f.request('connect', 'abandoned-http').result).status, 200);
  assertConnected(f);
  assert.equal(f.count('create'), 1);
  assert.equal(f.count('attachTun'), 1);
});

for (const failure of ['stop', 'destroy']) {
  test(`完整停止${failure}失败不写回执，重试保留实例代次`, async t => {
    const f = fixture(t);
    await f.warm();
    await connect(f);
    const active = f.activeInstance();
    f.fail(failure);
    f.instance.onDestroy();
    await assert.rejects(f.instance.cleanupPending);
    assert.equal(f.receipt(), undefined);
    assert.ok(f.count('stop') >= 1);
    assert.ok(f.count('destroy') >= 1);
    await f.shutdown();
    assert.equal(f.snapshot().running, false);
    assert.equal(f.snapshot().tunAttached, false);
    assert.equal(f.platformCreated, false);
    assert.deepEqual(f.receipt(), active);
  });
}

test('create等待期间secret换代拒绝旧宿主继续连接并释放迟到资源', async t => {
  const f = fixture(t);
  await f.warm();
  const gate = f.hold('create');
  const request = f.request('connect', 'old-secret-connect');
  await gate.entered;
  f.replaceRuntime({ secret: 'new.fixture.secret' });
  gate.release();
  assert.equal((await request.result).status, 409);
  assert.equal(f.count('attachTun'), 0);
  assert.equal(f.platformCreated, false);
  assert.equal(f.snapshot().vpnCreated, false);
  assert.equal(f.snapshot().tunAttached, false);
});

test('完整退出等平台destroy完成后才写实例停止回执', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  const gate = f.hold('destroy');
  f.instance.onDestroy();
  const cleanup = f.instance.cleanupPending;
  await gate.entered;
  assert.equal(f.receipt(), undefined);
  assert.equal(f.platformCreated, true);
  gate.release();
  await cleanup;
  assert.equal(f.platformCreated, false);
  assert.equal(f.snapshot().running, false);
  assert.equal(f.snapshot().tunAttached, false);
  assert.deepEqual(f.receipt(), f.activeInstance());
});

test('停止回执只对应被清理的实例，不能伪装成后来实例的停止证据', async t => {
  const f = fixture(t);
  await f.warm();
  const original = f.activeInstance();
  const gate = f.hold('stop');
  f.instance.onDestroy();
  await gate.entered;
  const newer = { secret: original.secret, instance: 'newer.instance' };
  f.replaceInstance(newer);
  assert.equal(f.receipt(), undefined);
  gate.release();
  await f.instance.cleanupPending;
  assert.notDeepEqual(f.receipt(), newer);
  if (f.receipt() !== undefined) assert.deepEqual(f.receipt(), original);
});

test('单一原生命令注册仍路由真实profiles/changed处理器，普通断开后可继续更新', async t => {
  const f = fixture(t);
  await f.warm();
  assert.equal(f.registrations, 1);
  assert.equal((await f.command('profiles/changed', {}).result).status, 200);
  assert.equal(f.schedulers[0].reschedules, 1);
  assert.equal((await f.request('disconnect', 'already-stopped').result).status, 200);
  const reply = await f.command('profiles/changed', {}).result;
  assert.equal(reply.status, 200);
  assert.equal(reply.body.ok, true);
  assert.equal(f.schedulers[0].reschedules, 2);
  assert.equal(f.registrations, 1);
  assert.equal(f.schedulers[0].running, true);
});

test('在线图标集命令经 VPN 下载，成功提交后只返回回执', async t => {
  const f = fixture(t);
  await f.warm();
  await connect(f);
  const request = { expectedRevision: 'default', revision: 'icons.1', id: '', name: '',
    url: 'https://example.test/icons.json' };
  assert.deepEqual(await f.command('profiles/icon-set-download', request).result, { status: 200, body: { ok: true } });
  assert.equal(f.count('downloadIconSet'), 1);
  const catalog = JSON.parse(f.files.get(`${filesDir}/profiles/icon-sets.json`));
  assert.equal(catalog.revision, 'icons.1');
  assert.equal(catalog.sets[0].name, 'Fixture icons');
  assert.equal((await f.command('profiles/icon-set-download', request).result).status, 409);
  assert.equal(f.count('downloadIconSet'), 1);
});
