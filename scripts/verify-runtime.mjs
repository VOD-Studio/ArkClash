import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import test, { beforeEach } from 'node:test';
import './vpn-lifecycle-cases.mjs';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const source = readFileSync(new URL('../entry/src/main/ets/client/CoreClient.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'CoreClient.ts',
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
}).outputText;
const state = {};
class Clock extends Date { static now() { return state.now; } }
const context = { filesDir: '/isolated-fixture', applicationInfo: { name: 'fixture.application' } };
const ready = {
  profile: 'fixture', running: true, intent: 'started', forward: 'running', sessionMode: 'tun',
  tunAttached: true, vpnCreated: true, listenersOpen: true, startedAt: 1, bootId: 'fixture.boot', revision: 1, configRevision: 1,
  mode: 'rule', version: 'fixture'
};
const kits = {
  '@kit.AbilityKit': {},
  '@kit.CryptoArchitectureKit': { cryptoFramework: {
    createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(16).fill(++state.random) }) })
  } },
  '@kit.NetworkKit': {
    http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0 },
      createHttp: () => ({
        async request(url, options) {
          if (options.method === 'POST') {
            state.commands.push({ url, body: JSON.parse(options.extraData) });
            await state.commandGate;
            if (state.commandError) throw state.commandError;
            state.status = url.endsWith('/disconnect') ? {
              ...state.status, intent: 'stopped', forward: 'stopped', vpnCreated: false,
              tunAttached: false, listenersOpen: false, startedAt: 0, revision: state.status.revision + 1
            } : { ...state.status, ...ready, bootId: state.status.bootId,
              configRevision: state.status.configRevision, revision: state.status.revision + 1 };
            if (state.commandTimeout) throw new Error('HTTP timeout');
            return { responseCode: 200, result: JSON.stringify(state.status) };
          }
          const status = state.status;
          state.requestingStatus = true;
          await state.statusGate;
          if (status === undefined) { throw new Error('controller unavailable'); }
          return { responseCode: 200, result: JSON.stringify(status) };
        },
        destroy() {}
      })
    },
    vpnExtension: {
      async startVpnExtensionAbility() {
        state.started++;
        await state.startGate;
        if (state.denyAuthorization) { throw undefined; }
        if (state.startError) { throw state.startError; }
        state.active = true;
        state.instance = { secret: state.runtime.secret, instance: `instance.${state.started}` };
      },
      async stopVpnExtensionAbility() {
        state.stopped++;
        if (state.stopError) { throw state.stopError; }
        if (state.stopCleans) { state.receipt = state.runtime.secret; state.active = false; }
      }
    }
  },
  '../shared/Runtime': {
    CONTROLLER_ADDRESS: '127.0.0.1:19090',
    readRuntime: async () => state.runtime,
    readRuntimeInstance: async () => state.instance,
    takeCoreError: async () => undefined,
    writeRuntime: async (_filesDir, runtime) => {
      state.runtime = runtime;
      state.writingRuntime = true;
      await state.runtimeWriteGate;
    },
    runtimeMayBeActive: async () => state.active && state.receipt !== state.runtime.secret
  },
  '../shared/profiles/Store': {
    async withProfileStorage(_filesDir, operation) { await state.storageGate; return operation(); }
  },
  './VpnNetworkSettings': { async readVpnNetworkSettings() { return state.networkSettings; } },
  './Controller': {}
};
const module = { exports: {} };
const realm = vm.createContext({
  Date: Clock, Uint8Array, Promise, Error, JSON, Number, Math,
  setTimeout(callback, milliseconds) { state.now += milliseconds; queueMicrotask(callback); },
  require(name) { assert.ok(name in kits, `unexpected module ${name}`); return kits[name]; },
  module, exports: module.exports
});
vm.runInContext(compiled, realm);
const core = module.exports;

function loadConsumer(relative, bindings, modules = new Map()) {
  const file = new URL(relative, import.meta.url);
  if (modules.has(file.href)) { return modules.get(file.href).exports; }
  const consumer = { exports: {} };
  modules.set(file.href, consumer);
  const source = readFileSync(file, 'utf8')
    .replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const code = ts.transpileModule(source, {
    fileName: 'consumer.ts', compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  vm.runInNewContext(code, {
    Date: Clock, Promise, Error, JSON, Number, Math, Set, Map,
    $r: key => key,
    setTimeout(callback, milliseconds) { state.now += milliseconds; queueMicrotask(callback); },
    require(name) {
      if (name in bindings) { return bindings[name]; }
      assert.ok(name.startsWith('.'), `unexpected consumer module ${name}`);
      return loadConsumer(new URL(`${name}.ets`, file), bindings, modules);
    },
    module: consumer, exports: consumer.exports
  });
  return consumer.exports;
}

const prefs = {
  getSync(key, fallback) { return state.saved[key] ?? fallback; }, hasSync(key) { return key in state.saved; },
  putSync(key, value) { state.saved[key] = value; },
  async flush() { if (state.flushError) { throw new Error('fixture preference storage failure'); } }
};

// 使用真实设置队列和原子写辅助函数，仅在平台写调用处控制提交完成。
const geoSettings = loadConsumer('../entry/src/main/ets/shared/GeoResources.ets', {
  '@kit.BasicServicesKit': {},
  '@kit.ArkTS': { url: { URL: { parseURL: source => new URL(source) } } },
  '@kit.CoreFileKit': { fileIo: {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_WRITE: 8 },
    async access() { return false; },
    async readText() {
      if (state.geoText === undefined) throw Object.assign(new Error('missing'), { code: 13900002 });
      return state.geoText;
    },
    async open() { return { fd: 1, async lock() {} }; },
    async write(_fd, text) {
      state.geoWriting = true;
      await state.geoSaveGate;
      if (state.geoSaveError) throw new Error('disk failure');
      state.geoTemporary = text;
      return Buffer.byteLength(text);
    },
    async close() {},
    async rename() { state.geoText = state.geoTemporary; }
  } }
});
const connectionBindings = {
  '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.NetworkKit': {},
  '@kit.ArkData': { preferences: { getPreferencesSync: () => prefs } },
  './Controller': {},
  './CoreClient': core, './Proxies': { flushProxySelections: async () => {} },
  './Traffic': { traffic: { reset() {} } }, '../shared/Runtime': {
    CONTROLLER_ADDRESS: '127.0.0.1:19090', readRuntime: async () => state.runtime,
    runtimeMayBeActive: async () => state.active
  },
  '../shared/GeoResources': geoSettings
};
const { Connection } = loadConsumer('../entry/src/main/ets/client/Connection.ets', {
  ...connectionBindings, './ControllerSocket': { ControllerSocket: class { start() {} stop() {} } }
});
const runControls = loadConsumer('../entry/src/main/ets/features/home/HomeRunControls.ets', {});

beforeEach(() => {
  Object.assign(state, { now: 1000, started: 0, stopped: 0, status: undefined,
    runtime: { secret: 'fixture-session', stack: 'gvisor', mode: 'rule' },
    receipt: undefined, startError: undefined, stopError: undefined, stopCleans: false,
    active: false, flushError: false, saved: {}, writingRuntime: false,
    instance: { secret: 'fixture-session', instance: 'fixture.instance' },
    random: 0, commands: [], commandGate: Promise.resolve(), commandTimeout: false, commandError: undefined,
    denyAuthorization: false, networkSettings: undefined,
    requestingStatus: false, statusGate: Promise.resolve(), startGate: Promise.resolve(),
    runtimeWriteGate: Promise.resolve(), storageGate: Promise.resolve(),
    geoText: undefined, geoTemporary: undefined, geoWriting: false, geoSaveError: false, geoSaveGate: Promise.resolve() });
});

test('DNS 覆写离线按版本提交，在线超时只凭落盘版本确认', async () => {
  let disk;
  let active = false;
  let request;
  let timeoutAfterCommit = true;
  const dns = loadConsumer('../entry/src/main/ets/client/DnsOverrides.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { url: { URL: { parseURL: value => new URL(value) } },
      util: { TextEncoder: class { encodeInto(value) { return Buffer.from(value); } } } },
    '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' } } },
    '@kit.CoreFileKit': { fileIo: { async readText() {
      if (disk === undefined) throw Object.assign(new Error('missing'), { code: 13900002 });
      return disk;
    } } },
    '../shared/Files': { async writeTextAsync(_path, value) { disk = value; } },
    '../shared/Runtime': { async runtimeMayBeActive() { return active; } },
    '../shared/profiles/Store': { newId: prefix => prefix + ++state.random, withProfileStorage: (_dir, op) => op(),
      async profileDataPath(dir, name) { return dir + '/' + name; } },
    './CoreClient': { async readCoreHostStatus() {
      return active ? { state: 'running', status: { bootId: 'dns.boot' } } : { state: 'stopped' };
    } },
    './Controller': { async call(_dir, _method, route, body) {
      assert.equal(route, '/arkclash/dns/settings');
      request = JSON.parse(body);
      if (timeoutAfterCommit) disk = JSON.stringify(request.settings);
      throw new Error('timeout');
    } }
  });
  const initial = await dns.readDnsOverrides(context.filesDir);
  await assert.rejects(dns.saveDnsOverrides(context, initial.revision, { nameserver: [] }), /dns_override_invalid/);
  await assert.rejects(dns.saveDnsOverrides(context, initial.revision, { 'fake-ip-range6': '198.18.0.1/16' }),
    /dns_override_invalid/);
  const policy = dns.parseDnsPolicyText('+.example.test = 1.1.1.1\n+.other.test = 9.9.9.9\n' +
    '+.example.test = https://dns.example.test/dns-query?flag=1');
  assert.throws(() => dns.parseDnsPolicyText('+.example.test'), /dns_override_invalid/);
  assert.deepEqual(JSON.parse(JSON.stringify(policy)), [
    { pattern: '+.example.test', servers: ['1.1.1.1', 'https://dns.example.test/dns-query?flag=1'] },
    { pattern: '+.other.test', servers: ['9.9.9.9'] }
  ]);
  assert.equal(dns.dnsPolicyText(policy),
    '+.example.test = 1.1.1.1\n+.example.test = https://dns.example.test/dns-query?flag=1\n+.other.test = 9.9.9.9');
  const entries = { ipv6: false, 'default-nameserver': ['2001:4860:4860::8888'], fallback: [],
    'nameserver-policy': policy, 'cache-max-size': 0, 'fake-ip-range6': 'fd00::1/64', 'fallback-filter.geoip': false };
  const saved = await dns.saveDnsOverrides(context, initial.revision, entries);
  assert.deepEqual(JSON.parse(disk).entries, JSON.parse(JSON.stringify(entries)));
  await assert.rejects(dns.saveDnsOverrides(context, initial.revision, {}), /dns_override_conflict/);
  active = true;
  const removed = await dns.saveDnsOverrides(context, saved.revision, {});
  assert.equal(request.bootId, 'dns.boot');
  assert.equal(request.expectedRevision, saved.revision);
  assert.deepEqual(JSON.parse(disk), { revision: removed.revision, entries: {} });
  timeoutAfterCommit = false;
  await assert.rejects(dns.saveDnsOverrides(context, removed.revision, { 'prefer-h3': true }), /timeout/);
});

test('连接等待已进入提交的离线配置，取消不会启动扩展', async () => {
  let release;
  let current = true;
  state.storageGate = new Promise(resolve => { release = resolve; });
  const pending = core.startCore(context, 'rule', undefined, () => current);
  await Promise.resolve();
  assert.equal(state.started, 0);
  current = false;
  release();
  await assert.rejects(pending, /启动已取消/);
  assert.equal(state.started, 0);
  assert.equal(state.runtime.secret, 'fixture-session');
});

test('Connection等待真实Geo设置提交后才能启动', async () => {
  let release;
  state.geoSaveGate = new Promise(resolve => { release = resolve; });
  const saving = geoSettings.saveGeoSettings(context.filesDir, geoSettings.defaultGeoSettings());
  const connection = new Connection();
  connection.restore(context);
  state.status = ready;
  const connecting = connection.connect(context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(state.geoWriting, true);
  assert.equal(state.started, 0);
  release();
  await saving;
  await connecting;
  assert.equal(state.started, 1);
  assert.equal(JSON.parse(state.geoText).revision, (await geoSettings.readGeoSettings(context.filesDir)).revision);
});

test('Geo保存等待期间断开仅取消转发，预热核心继续就绪', async () => {
  let release;
  state.status = warm;
  state.geoSaveGate = new Promise(resolve => { release = resolve; });
  const saving = geoSettings.saveGeoSettings(context.filesDir, geoSettings.defaultGeoSettings());
  const connection = new Connection();
  connection.restore(context);
  const connecting = connection.connect(context);
  await new Promise(resolve => setImmediate(resolve));
  const stopping = connection.disconnect(context);
  release();
  await Promise.all([saving, connecting, stopping]);
  assert.equal(state.started, 1);
  assert.equal(state.stopped, 0);
  assert.equal(connection.coreReady, true);
  assert.equal(connection.connected, false);
  assert.equal(state.commands.some(command => command.url.endsWith('/connect')), false);
});

test('Geo保存失败阻止连接，显式恢复后屏障可再次使用', async () => {
  state.geoSaveError = true;
  await assert.rejects(geoSettings.saveGeoSettings(context.filesDir, geoSettings.defaultGeoSettings()), /geo_io/);
  const connection = new Connection();
  connection.restore(context);
  await assert.rejects(connection.connect(context), /geo_io/);
  assert.equal(state.started, 0);
  state.geoSaveError = false;
  await geoSettings.resetGeoSettings(context.filesDir);
  await geoSettings.flushGeoSettings();
});

test('只有controller可达且没有TUN时不能宣称连接成功', async () => {
  state.status = { ...ready, tunAttached: false, forward: 'stopped', running: false };
  state.stopCleans = true;
  await assert.rejects(core.startCore(context, 'rule', undefined, () => true), /启动超时/);
});

test('TUN和内核同时就绪才返回成功', async () => {
  state.status = ready;
  const result = await core.startCore(context, 'rule', undefined, () => true);
  assert.equal(result.bootId, ready.bootId);
  assert.equal(result.tunAttached, true);
});

test('controller失联且没有清理回执时停止失败', async () => {
  state.active = true;
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('同会话清理完成允许确认controller关闭后的停止', async () => {
  state.receipt = state.runtime.secret;
  await core.stopCore(context);
});

test('旧会话回执不能把当前会话误判为已停止', async () => {
  state.active = true;
  state.receipt = 'previous-session';
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('系统停止失败且内核仍运行时传播错误', async () => {
  state.active = true;
  state.status = ready;
  state.stopError = new Error('fixture system stop rejected');
  await assert.rejects(core.stopCore(context), /fixture system stop rejected/);
});

test('启动初始空快照不能证明系统VPN已销毁', async () => {
  state.active = true;
  state.status = { ...ready, running: false, tunAttached: false, listenersOpen: false, bootId: '', revision: 0 };
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('扩展启动前失败后，下一次按钮动作可直接连接', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.startError = new Error('fixture extension start rejected');
  await assert.rejects(connection.connect(context), /fixture extension start rejected/);
  assert.equal(runControls.homeShouldStopRuntime(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached, connection.vpnCreated, connection.hostState), false);
  state.startError = undefined;
  state.status = ready;
  await connection.connect(context);
  assert.equal(connection.connected, true);
  assert.equal(state.started, 2);
  assert.equal(state.stopped, 0);
});

test('连接耗时保存失败不会撤销已确认的转发事实', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.status = ready;
  state.flushError = true;
  await connection.connect(context);
  assert.equal(connection.connected, true);
  assert.equal(connection.tunAttached, true);
  assert.equal(connection.forward, 'running');
  assert.equal(connection.intent, 'started');
});

test('controller失联但宿主未清理时不能退回离线配置写入', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.status = ready;
  await connection.connect(context);
  state.active = true;
  state.status = undefined;
  await assert.rejects(connection.recheck(context), /尚未确认代理状态/);
  assert.equal(connection.tunAttached, true);
  assert.equal(connection.hostState, 'unknown');
  assert.equal(connection.offlineWritable, false);
  state.active = false;
  assert.equal(await connection.recheck(context), false);
  assert.equal(connection.intent, 'stopped');
  assert.equal(connection.tunAttached, false);
  assert.equal(connection.hostState, 'stopped');
  assert.equal(connection.offlineWritable, true);
});

test('真实核心已运行但尚未附加TUN时配置操作仍交给核心', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.status = { ...ready, tunAttached: false };
  state.active = true;
  assert.equal(await connection.recheck(context), true);
  assert.equal(connection.connected, false);
});

test('系统复用secret重建扩展后，旧实例及迟到清理回执都不算新实例停止', async () => {
  const { fixture, runtime } = runtimeFixture();
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  await runtime.writeRuntime('/fixture', { secret: 'same-secret', stack: 'gvisor', mode: 'rule' });
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.one');
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
  await runtime.writeRuntimeStopped('/fixture', 'same-secret', 'instance.one');
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'same-secret'), true);
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), false);
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.two');
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'same-secret'), false);
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
  await runtime.writeRuntimeStopped('/fixture', 'same-secret', 'instance.one');
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'same-secret'), false);
  await runtime.writeRuntimeStopped('/fixture', 'same-secret', 'instance.two');
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'same-secret'), true);
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'different-secret'), false);
});

test('订阅在异步读盘期间停止后不会打开迟到WebSocket', async () => {
  let release;
  const storage = new Promise(resolve => { release = resolve; });
  let opened = 0;
  const { ControllerSocket } = loadConsumer('../entry/src/main/ets/client/ControllerSocket.ets', {
    '@kit.NetworkKit': { webSocket: { createWebSocket() { opened++; return {}; } } },
    '../shared/Runtime': { readRuntime: async () => { await storage; return state.runtime; } }
  });
  const socket = new ControllerSocket('/traffic', () => {});
  socket.start(context.filesDir);
  socket.stop();
  release();
  for (let index = 0; index < 5; index++) await Promise.resolve();
  assert.equal(opened, 0);
  assert.equal(socket.active, false);
});

test('探测在异步读盘期间取消后不创建网络请求', { timeout: 5000 }, async () => {
  let release;
  const storage = new Promise(resolve => { release = resolve; });
  let entered;
  const reading = new Promise(resolve => { entered = resolve; });
  let opened = 0;
  const { RoutedProbeRequest } = loadConsumer('../entry/src/main/ets/client/RoutedProbe.ets', {
    '@kit.BasicServicesKit': {}, '@kit.ArkTS': {},
    '@kit.NetworkKit': { http: { createHttp() { opened++; return {}; } } },
    '../shared/Runtime': {
      CONTROLLER_ADDRESS: '127.0.0.1:19090',
      readRuntime: async () => { entered(); await storage; return state.runtime; }
    }
  });
  const request = new RoutedProbeRequest();
  const pending = request.run(context.filesDir,
    { url: 'https://example.invalid/', method: 'GET', bodyMode: 'none' }, 1000, true);
  await reading;
  assert.equal(opened, 0);
  request.cancel();
  release();
  await assert.rejects(pending, error => error.reason === 'cancelled');
  assert.equal(opened, 0);
});

test('运行配置异步写入期间取消后不会启动扩展', async () => {
  let release;
  let current = true;
  state.runtimeWriteGate = new Promise(resolve => { release = resolve; });
  const pending = core.startCore(context, 'rule', undefined, () => current);
  while (!state.writingRuntime) await Promise.resolve();
  current = false;
  release();
  await assert.rejects(pending, /启动已取消/);
  assert.equal(state.started, 0);
});

test('未知宿主拒绝运行偏好写入，确认停止后恢复', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.status = ready;
  await connection.connect(context);
  const saved = { ...state.saved };
  state.status = undefined;
  await assert.rejects(connection.recheck(context), /尚未确认代理状态/);
  await assert.rejects(connection.changeMode('global'), /尚未确认代理状态/);
  await assert.rejects(connection.changeAllowLan(true), /尚未确认代理状态/);
  assert.deepEqual(state.saved, saved);
  state.active = false;
  assert.equal(await connection.recheck(context), false);
  await connection.changeMode('global');
  assert.equal(state.saved.outboundMode, 'global');
});

function runtimeFixture() {
  const files = new Map();
  const fixture = { processes: [{ pid: 41 }], processError: undefined, duringQuery: undefined };
  const runtime = loadConsumer('../entry/src/main/ets/shared/Runtime.ets', {
    '@kit.AbilityKit': { appManager: { async getRunningProcessInformation() {
      if (fixture.processError) throw fixture.processError;
      await fixture.duringQuery?.();
      return fixture.processes;
    } } },
    '@kit.ArkTS': { process: { pid: 41 } },
    '@kit.CoreFileKit': { fileIo: { access: async path => files.has(path) } },
    './Files': {
      writeTextAsync: async (path, text) => { files.set(path, text); },
      readText: async path => files.get(path)
    }
  });
  return { files, fixture, runtime };
}

test('异常死亡及设备重启留下的实例由系统进程证据恢复，不删除运行文件', async () => {
  const { files, fixture, runtime } = runtimeFixture();
  await runtime.beginRuntimeInstance('/fixture', 'old-secret', 'old-instance');
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
  fixture.processes = [{ pid: 41 }];
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), false);
  assert.equal(files.has('/fixture/runtime-instance.json'), true);
  assert.equal(files.has('/fixture/runtime-stopped.json'), false);
  assert.equal(await runtime.wasRuntimeStopped('/fixture', 'old-secret'), false);
});

test('活宿主失联、PID复用、系统查询失败或未包含调用方均不能证明停止', async () => {
  const { fixture, runtime } = runtimeFixture();
  await runtime.beginRuntimeInstance('/fixture', 'session', 'instance');
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
  fixture.processError = new Error('system process query unavailable');
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
  fixture.processError = undefined;
  fixture.processes = [];
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
});

test('系统查询期间扩展换代时旧进程缺席不能证明新实例停止', async () => {
  const { fixture, runtime } = runtimeFixture();
  await runtime.beginRuntimeInstance('/fixture', 'session', 'instance.one');
  fixture.duringQuery = async () => runtime.beginRuntimeInstance('/fixture', 'session', 'instance.two');
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
});

test('首次进入未知状态不会自行生成启动意图，死宿主恢复后直接启动', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.active = true;
  await assert.rejects(connection.recheck(context), /尚未确认代理状态/);
  assert.equal(connection.intent, 'stopped');
  assert.equal(connection.offlineWritable, false);
  assert.equal(runControls.homeRuntimeAppearsStarted(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached, connection.vpnCreated), false);
  assert.equal(runControls.homeShouldStopRuntime(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached, connection.vpnCreated, connection.hostState), true);
  assert.equal(runControls.homeRunActionLabel(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached, connection.vpnCreated, connection.hostState), 'app.string.dash_runtime_stop_confirm');
  state.active = false;
  assert.equal(await connection.recheck(context), false);
  state.status = ready;
  await connection.connect(context);
  assert.equal(connection.connected, true);
});

test('停止已异常死亡的宿主不用等待永远不会出现的清理回执', async () => {
  state.active = false;
  await core.stopCore(context);
  assert.equal(state.now, 1000);
});

test('runtime写入和系统启动回调等待期间，所有消费者都保留未知宿主', async () => {
  let releaseWrite;
  let releaseStart;
  state.runtimeWriteGate = new Promise(resolve => { releaseWrite = resolve; });
  state.startGate = new Promise(resolve => { releaseStart = resolve; });
  state.status = ready;
  const pending = core.startCore(context, 'rule', undefined, () => true);
  while (!state.writingRuntime) await Promise.resolve();
  assert.equal((await core.readCoreHostStatus(context)).state, 'unknown');
  const observer = new Connection();
  observer.restore(context);
  await assert.rejects(observer.recheck(context), /尚未确认代理状态/);
  assert.equal(observer.offlineWritable, false);
  releaseWrite();
  while (state.started === 0) await Promise.resolve();
  assert.equal(state.active, false);
  assert.equal((await core.readCoreHostStatus(context)).state, 'unknown');
  releaseStart();
  await pending;
  assert.equal((await core.readCoreHostStatus(context)).state, 'running');
});

test('停止早于系统创建VPN进程时等待晚到启动收尾，不接受迟到成功', async () => {
  let releaseStart;
  state.startGate = new Promise(resolve => { releaseStart = resolve; });
  state.status = ready;
  state.stopCleans = true;
  const starting = core.startCore(context, 'rule', undefined, () => true);
  const rejected = assert.rejects(starting, /启动已取消/);
  while (state.started === 0) await Promise.resolve();
  let stopped = false;
  const stopping = core.stopCore(context).then(() => { stopped = true; });
  for (let turn = 0; turn < 10; turn++) await Promise.resolve();
  assert.equal(stopped, false);
  assert.equal((await core.readCoreHostStatus(context)).state, 'unknown');
  releaseStart();
  await Promise.all([rejected, stopping]);
  assert.equal(state.active, false);
  assert.equal((await core.readCoreHostStatus(context)).state, 'stopped');
});

test('晚到HTTP运行快照不能越过secret或实例换代', async () => {
  for (const change of ['secret', 'instance']) {
    let releaseStatus;
    state.requestingStatus = false;
    state.statusGate = new Promise(resolve => { releaseStatus = resolve; });
    state.status = ready;
    state.instance = { secret: state.runtime.secret, instance: 'instance.one' };
    const pending = core.probeCore(context);
    while (!state.requestingStatus) await Promise.resolve();
    if (change === 'secret') state.runtime = { ...state.runtime, secret: 'new-secret' };
    else state.instance = { secret: state.runtime.secret, instance: 'instance.two' };
    releaseStatus();
    assert.equal(await pending, undefined);
  }
});

test('已发出的就绪请求在取消后返回成功也不能成为连接成功', async () => {
  let releaseStatus;
  let current = true;
  state.statusGate = new Promise(resolve => { releaseStatus = resolve; });
  state.status = ready;
  state.stopCleans = true;
  const pending = core.startCore(context, 'rule', undefined, () => current);
  const rejected = assert.rejects(pending, /启动已取消/);
  while (!state.requestingStatus) await Promise.resolve();
  current = false;
  releaseStatus();
  await rejected;
  assert.equal(state.active, false);
});

test('系统查询期间runtime会话改变会丢弃旧的停止证据', async () => {
  const { fixture, runtime } = runtimeFixture();
  await runtime.writeRuntime('/fixture', { secret: 'old-secret', stack: 'gvisor', mode: 'rule' });
  await runtime.beginRuntimeInstance('/fixture', 'old-secret', 'old-instance');
  fixture.duringQuery = async () => runtime.writeRuntime('/fixture', {
    secret: 'new-secret', stack: 'gvisor', mode: 'rule'
  });
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
});

function runtimeConsumers() {
  const { files, fixture, runtime } = runtimeFixture();
  const localContext = { ...context, filesDir: '/fixture' };
  Object.assign(fixture, { starts: 0, stops: 0, stopCleans: true, stopError: undefined });
  const network = { ...kits['@kit.NetworkKit'], vpnExtension: {
    async startVpnExtensionAbility() {
      fixture.starts++;
      fixture.processes = [{ pid: 41 }, { pid: 87 }];
      const config = await runtime.readRuntime('/fixture');
      await runtime.beginRuntimeInstance('/fixture', config.secret, `instance.${fixture.starts}`);
    },
    async stopVpnExtensionAbility() {
      fixture.stops++;
      if (fixture.stopError) throw fixture.stopError;
      if (fixture.stopCleans) {
        const instance = await runtime.readRuntimeInstance('/fixture');
        if (instance) await runtime.writeRuntimeStopped('/fixture', instance.secret, instance.instance);
        fixture.processes = [{ pid: 41 }];
      }
    }
  } };
  const client = loadConsumer('../entry/src/main/ets/client/CoreClient.ets', {
    ...kits, '@kit.NetworkKit': network, '../shared/Runtime': runtime
  });
  const { Connection: ConsumerConnection } = loadConsumer('../entry/src/main/ets/client/Connection.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.NetworkKit': {},
    '@kit.ArkData': { preferences: { getPreferencesSync: () => prefs } },
    './Controller': {}, './ControllerSocket': { ControllerSocket: class { start() {} stop() {} } },
    './CoreClient': client, './Proxies': { flushProxySelections: async () => {} },
    './Traffic': { traffic: { reset() {} } }, '../shared/Runtime': runtime,
    '../shared/GeoResources': geoSettings
  });
  const connection = new ConsumerConnection();
  connection.restore(localContext);
  return { files, fixture, runtime, client, connection, context: localContext };
}

test('真实Connection和CoreClient恢复异常死亡实例后可启停，重进页面不自动启动', async () => {
  const { files, fixture, runtime, client, connection, context: localContext } = runtimeConsumers();
  await runtime.writeRuntime('/fixture', { secret: 'old-secret', stack: 'gvisor', mode: 'rule' });
  await runtime.beginRuntimeInstance('/fixture', 'old-secret', 'dead-instance');
  assert.equal(await connection.recheck(localContext), false);
  assert.equal(connection.intent, 'stopped');
  assert.equal(connection.offlineWritable, true);
  assert.equal(fixture.starts, 0);
  assert.equal(files.has('/fixture/runtime-instance.json'), true);
  state.status = ready;
  await connection.connect(localContext);
  assert.equal(connection.connected, true);
  state.status = undefined;
  await assert.rejects(connection.recheck(localContext), /尚未确认代理状态/);
  assert.equal(connection.offlineWritable, false);
  assert.equal(connection.intent, 'started');
  await connection.disconnect(localContext);
  assert.equal(connection.intent, 'stopped');
  assert.equal(connection.offlineWritable, true);
  assert.equal((await client.readCoreHostStatus(localContext)).state, 'stopped');
});

test('真实消费者遇到复用secret的新活实例时拒绝旧清理回执，保留停止入口', async () => {
  const { fixture, runtime, connection, context: localContext } = runtimeConsumers();
  await runtime.writeRuntime('/fixture', { secret: 'same-secret', stack: 'gvisor', mode: 'rule' });
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.one');
  await runtime.writeRuntimeStopped('/fixture', 'same-secret', 'instance.one');
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.two');
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  fixture.stopError = new Error('system refused stop');
  await assert.rejects(connection.recheck(localContext), /尚未确认代理状态/);
  assert.equal(connection.intent, 'stopped');
  assert.equal(connection.offlineWritable, false);
  assert.equal(runControls.homeShouldStopRuntime(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached, connection.vpnCreated, connection.hostState), true);
  await assert.rejects(connection.disconnect(localContext), /system refused stop/);
  assert.equal(connection.hostState, 'unknown');
  fixture.stopError = undefined;
  await connection.disconnect(localContext);
  assert.equal(connection.offlineWritable, true);
});

test('真实Connection不发布跨扩展实例晚到的旧boot，重查后只采用新boot', async () => {
  const { fixture, runtime, connection, context: localContext } = runtimeConsumers();
  await runtime.writeRuntime('/fixture', { secret: 'same-secret', stack: 'gvisor', mode: 'rule' });
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.one');
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  let releaseStatus;
  state.status = { ...ready, bootId: 'old.boot' };
  state.statusGate = new Promise(resolve => { releaseStatus = resolve; });
  const pending = connection.recheck(localContext);
  const rejected = assert.rejects(pending, /尚未确认代理状态/);
  while (!state.requestingStatus) await Promise.resolve();
  await runtime.beginRuntimeInstance('/fixture', 'same-secret', 'instance.two');
  releaseStatus();
  await rejected;
  assert.equal(connection.bootId, '');
  assert.equal(connection.offlineWritable, false);
  state.status = { ...ready, bootId: 'new.boot' };
  state.statusGate = Promise.resolve();
  assert.equal(await connection.recheck(localContext), true);
  assert.equal(connection.bootId, 'new.boot');
});

test('缺少本UI的非空列表和不带secret的伪回执都保持未知', async () => {
  const { files, fixture, runtime } = runtimeFixture();
  fixture.processes = [{ pid: 87 }];
  files.set('/fixture/runtime-instance.json', JSON.stringify({ instance: 'invalid' }));
  files.set('/fixture/runtime-stopped.json', JSON.stringify({ instance: 'invalid' }));
  assert.equal(await runtime.wasRuntimeStopped('/fixture', undefined), false);
  assert.equal(await runtime.runtimeMayBeActive('/fixture'), true);
});

test('旧安装只有runtime及新扩展尚未写实例时，有其它本应用进程仍为未知', async () => {
  const { fixture, runtime, client, connection, context: localContext } = runtimeConsumers();
  await runtime.writeRuntime('/fixture', { secret: 'legacy-secret', stack: 'gvisor', mode: 'rule' });
  fixture.processes = [{ pid: 41 }, { pid: 87 }];
  assert.equal((await client.readCoreHostStatus(localContext)).state, 'unknown');
  await assert.rejects(connection.recheck(localContext), /尚未确认代理状态/);
  assert.equal(connection.offlineWritable, false);
  assert.equal(connection.intent, 'stopped');
  fixture.processes = [{ pid: 41 }];
  assert.equal(await connection.recheck(localContext), false);
  assert.equal(connection.offlineWritable, true);
});

test('诊断配置身份不随普通运行revision变化，旧快照不得回退身份', () => {
  const connection = new Connection();
  connection.applyStatus({ ...ready, revision: 10, configRevision: 4 });
  const route = connection.routeRevision;
  connection.applyStatus({ ...ready, revision: 11, configRevision: 4 });
  assert.notEqual(connection.routeRevision, route);
  assert.equal(connection.configRevision, 4);
  connection.applyStatus({ ...ready, revision: 9, configRevision: 99 });
  assert.equal(connection.configRevision, 4);
  connection.applyStatus({ ...ready, bootId: 'new.diagnostics.boot', revision: 1, configRevision: 1 });
  assert.equal(connection.bootId, 'new.diagnostics.boot');
  assert.equal(connection.configRevision, 1);
  connection.applyStopped();
  assert.equal(connection.configRevision, 0);
});

test('旧运行文件不恢复历史连接意图', async () => {
  const { files, runtime } = runtimeFixture();
  files.set('/fixture/runtime.json', JSON.stringify({
    secret: 'legacy-secret', stack: 'gvisor', mode: 'rule', vpnIntent: 'started'
  }));
  const config = await runtime.readRuntime('/fixture');
  assert.equal(config.vpnIntent, 'stopped');
  assert.equal(config.vpnOperation, '');
});

test('偏好短提交保留后来写入的断开操作 token 和网络快照', async () => {
  let release;
  state.storageGate = new Promise(resolve => { release = resolve; });
  state.runtime = { secret: 'session', stack: 'gvisor', mode: 'rule',
    vpnIntent: 'started', vpnOperation: 'connect-operation' };
  const saving = core.updateRuntimeOptions(context.filesDir, 'global', true);
  state.runtime = { ...state.runtime, vpnIntent: 'stopped', vpnOperation: 'disconnect-operation',
    network: { stack: 'mixed', mtu: 1400 } };
  release();
  await saving;
  assert.equal(state.runtime.vpnIntent, 'stopped');
  assert.equal(state.runtime.vpnOperation, 'disconnect-operation');
  assert.equal(state.runtime.mode, 'global');
  assert.equal(state.runtime.allowLan, true);
  assert.deepEqual(state.runtime.network, { stack: 'mixed', mtu: 1400 });
});

const warm = { ...ready, intent: 'stopped', forward: 'stopped', tunAttached: false,
  vpnCreated: false, listenersOpen: false, startedAt: 0 };

test('预热允许空配置，不连接VPN且复用同一认证实例', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.status = { ...warm, profile: '' };
  await connection.ensureReady(context);
  assert.equal(connection.coreReady, true);
  assert.equal(connection.connected, false);
  assert.equal(connection.coreStarting, false);
  assert.equal(connection.state, 0);
  assert.equal(state.commands.length, 0);
  const secret = state.runtime.secret;
  await connection.ensureReady(context);
  assert.equal(state.started, 1);
  assert.equal(state.runtime.secret, secret);
});

test('诊断捕获绑定已挂载的UI接收端和认证boot，不随前后台、普通断开或配置切换停止', async () => {
  const captures = [];
  const { Connection: CaptureConnection } = loadConsumer('../entry/src/main/ets/client/Connection.ets', {
    ...connectionBindings,
    '@kit.NetworkKit': {
      connection: { createNetConnection: () => ({ on() {}, register(done) { done(); }, unregister() {} }) },
      webSocket: { createWebSocket() {
        const handlers = new Map();
        return {
          closed: false,
          on(name, listener) { handlers.set(name, listener); },
          off(name) { handlers.delete(name); },
          async connect(address, options) {
            const url = new URL(address);
            if (url.pathname === '/arkclash/diagnostics/capture') {
              assert.equal(options.header.Authorization, 'Bearer fixture-session');
              assert.deepEqual([...url.searchParams.keys()], ['expectedBootId']);
              captures.push({ boot: url.searchParams.get('expectedBootId'), socket: this });
              handlers.get('message')(undefined, 'ready');
            }
            handlers.get('open')(undefined);
            return true;
          },
          async close() { this.closed = true; }
        };
      } }
    }
  });
  const connection = new CaptureConnection();
  const settle = () => new Promise(resolve => setImmediate(resolve));
  const bootId = 'fixture+boot&query';
  connection.restore(context);
  state.active = true;
  connection.setDiagnosticsReceiverMounted(true);
  await settle();
  assert.equal(captures.length, 0);

  state.status = { ...warm, bootId };
  await connection.recheck(context);
  await settle();
  assert.equal(captures.length, 1);
  assert.equal(captures[0].boot, bootId);
  assert.equal(connection.connected, false);
  connection.observe(context, true);
  await settle();
  connection.observe(context, false);
  state.status = undefined;
  await assert.rejects(connection.recheck(context), /尚未确认代理状态/);
  assert.equal(connection.hostState, 'unknown');
  assert.equal(captures[0].socket.closed, false);

  state.status = { ...ready, bootId, configRevision: 2, revision: 2 };
  await connection.recheck(context);
  await connection.disconnect(context);
  assert.equal(connection.connected, false);
  assert.equal(connection.configRevision, 2);
  assert.equal(captures.length, 1);
  assert.equal(captures[0].socket.closed, false);

  connection.diagnosticsCapture.fail('fixture');
  assert.equal(captures[0].socket.closed, true);
  connection.observe(context, true);
  await settle();
  assert.equal(captures.length, 2, 'authenticated foreground recheck re-arms inactive transport');

  state.status = { ...warm, bootId: 'new.boot' };
  await connection.recheck(context);
  await settle();
  assert.equal(captures.length, 3);
  assert.equal(captures[1].socket.closed, true);
  assert.equal(captures[2].boot, 'new.boot');
  connection.setDiagnosticsReceiverMounted(false);
  assert.equal(captures[2].socket.closed, true);
  await connection.recheck(context);
  assert.equal(captures.length, 3);

  connection.setDiagnosticsReceiverMounted(true);
  await settle();
  assert.equal(captures.length, 4);
  state.status = undefined;
  state.active = false;
  assert.equal(await connection.recheck(context), false);
  assert.equal(captures[3].socket.closed, true);
  connection.observe(context, false);
  connection.setDiagnosticsReceiverMounted(false);
});

test('预热单飞，连接和普通断开保持同一核心', async () => {
  state.status = warm;
  const results = await Promise.all([
    core.startCore(context, 'rule', undefined, () => true),
    core.startCore(context, 'rule', undefined, () => true)
  ]);
  assert.equal(results[0].bootId, results[1].bootId);
  assert.equal(state.started, 1);
  const connection = new Connection();
  connection.restore(context);
  await connection.connect(context);
  assert.equal(connection.connected, true);
  await connection.disconnect(context);
  assert.equal(connection.connected, false);
  assert.equal(connection.coreReady, true);
  assert.equal(connection.offlineWritable, false);
  assert.equal(state.stopped, 0);
  assert.equal(state.started, 1);
  assert.equal(connection.bootId, warm.bootId);
  assert.equal(connection.configRevision, warm.configRevision);
  assert.deepEqual(state.commands.map(command => command.url.split('/').at(-1)), ['connect', 'disconnect']);
});

test('系统 Promise 拒绝授权后立即结束启动，不等待 controller 或销毁不存在的 VPN', async () => {
  let deny;
  state.startGate = new Promise((_resolve, reject) => { deny = reject; });
  const pending = core.startCore(context, 'rule', undefined, () => true);
  while (state.started === 0) await Promise.resolve();
  assert.equal((await core.readCoreHostStatus(context)).state, 'unknown');
  deny();
  await assert.rejects(pending, /授权被拒绝/);
  assert.equal((await core.readCoreHostStatus(context)).state, 'stopped');
  assert.equal(state.stopped, 0);
  assert.equal(state.now, 1000);
});

test('自动预热拒绝本会话不重弹，显式动作可重试', async () => {
  const connection = new Connection();
  connection.restore(context);
  connection.foreground = true;
  state.denyAuthorization = true;
  await assert.rejects(connection.ensureReady(context, true), /授权被拒绝/);
  await connection.ensureReady(context, true);
  assert.equal(state.started, 1);
  state.denyAuthorization = false;
  state.status = warm;
  await connection.ensureReady(context);
  assert.equal(connection.coreReady, true);
  assert.equal(state.started, 2);
  assert.equal(state.commands.length, 0);
});

test('HTTP超时但服务端已完成时仅凭认证回读成功', async () => {
  state.status = warm;
  const status = await core.startCore(context, 'rule', undefined, () => true);
  state.commandTimeout = true;
  const connected = await core.connectVpn(context, status, () => true);
  assert.equal(connected.forward, 'running');
  const stopped = await core.disconnectVpn(context, connected, () => true);
  assert.equal(stopped.forward, 'stopped');
  assert.equal(state.stopped, 0);
});

test('迟到连接响应不能越过新操作token或实例', async () => {
  for (const change of ['token', 'instance']) {
    state.status = warm;
    const status = await core.startCore(context, 'rule', undefined, () => true);
    let release;
    state.commandGate = new Promise(resolve => { release = resolve; });
    const previous = state.commands.length;
    const pending = core.connectVpn(context, status, () => true);
    const rejected = assert.rejects(pending, /尚未确认/);
    while (state.commands.length === previous) await Promise.resolve();
    if (change === 'token') state.runtime = { ...state.runtime, vpnOperation: 'new-operation', vpnIntent: 'stopped' };
    else state.instance = { ...state.instance, instance: 'new-instance' };
    release();
    await rejected;
  }
});

test('宿主未知时预热不覆盖secret、不拉起扩展', async () => {
  state.active = true;
  const secret = state.runtime.secret;
  await assert.rejects(core.startCore(context, 'rule', undefined, () => true), /尚未确认/);
  assert.equal(state.runtime.secret, secret);
  assert.equal(state.started, 0);
});

test('自动预热等待本地设置时进入后台不启动、不进入Connecting', async () => {
  let release;
  const connection = new Connection();
  connection.restore(context);
  connection.foreground = true;
  connection.settingsPending = new Promise(resolve => { release = resolve; });
  const pending = connection.ensureReady(context, true);
  assert.equal(connection.coreStarting, true);
  assert.equal(connection.state, 0);
  connection.foreground = false;
  release();
  await pending;
  assert.equal(state.started, 0);
  assert.equal(connection.coreStarting, false);
});

test('HTTP失败且事实未完成不能冒充连接成功', async () => {
  state.status = warm;
  const status = await core.startCore(context, 'rule', undefined, () => true);
  state.commandError = new Error('transport failure');
  await assert.rejects(core.connectVpn(context, status, () => true), /尚未确认/);
  assert.equal(state.status.tunAttached, false);
});

test('自动预热途中显式连接复用启动，真实attach后才连接', async () => {
  let release;
  state.startGate = new Promise(resolve => { release = resolve; });
  state.status = warm;
  const connection = new Connection();
  connection.restore(context);
  connection.foreground = true;
  const warming = connection.ensureReady(context, true);
  while (state.started === 0) await Promise.resolve();
  const connecting = connection.connect(context);
  assert.equal(connection.connected, false);
  assert.equal(state.commands.length, 0);
  release();
  await Promise.all([warming, connecting]);
  assert.equal(state.started, 1);
  assert.equal(state.commands.length, 1);
  assert.equal(connection.connected, true);
});

test('自动预热系统启动等待期间断开不销毁核心或自动attach', async () => {
  let release;
  state.startGate = new Promise(resolve => { release = resolve; });
  state.status = warm;
  const connection = new Connection();
  connection.restore(context);
  connection.foreground = true;
  const warming = connection.ensureReady(context, true);
  while (state.started === 0) await Promise.resolve();
  const stopping = connection.disconnect(context);
  release();
  await Promise.all([warming, stopping]);
  assert.equal(state.started, 1);
  assert.equal(state.stopped, 0);
  assert.equal(connection.coreReady, true);
  assert.equal(connection.connected, false);
  assert.equal(connection.offlineWritable, false);
  assert.equal(state.commands.some(command => command.url.endsWith('/connect')), false);
});
