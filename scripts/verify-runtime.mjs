import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import test, { beforeEach } from 'node:test';

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
  tunAttached: true, listenersOpen: false, startedAt: 1, bootId: 'fixture.boot', revision: 1, configRevision: 1,
  mode: 'rule', version: 'fixture'
};
const kits = {
  '@kit.AbilityKit': {},
  '@kit.CryptoArchitectureKit': { cryptoFramework: {
    createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(16).fill(7) }) })
  } },
  '@kit.NetworkKit': {
    http: {
      RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 0 },
      createHttp: () => ({
        async request() {
          if (state.status === undefined) { throw new Error('controller unavailable'); }
          return { responseCode: 200, result: JSON.stringify(state.status) };
        },
        destroy() {}
      })
    },
    vpnExtension: {
      async startVpnExtensionAbility() {
        state.started++;
        if (state.startError) { throw state.startError; }
        state.active = true;
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
    takeCoreError: async () => undefined,
    writeRuntime: async (_filesDir, runtime) => {
      state.runtime = runtime;
      state.writingRuntime = true;
      await state.runtimeWriteGate;
    },
    wasRuntimeStopped: async (_filesDir, secret) => secret !== '' && secret === state.receipt,
    runtimeMayBeActive: async () => state.active
  },
  '../shared/profiles/Store': {
    async withProfileStorage(_filesDir, operation) { await state.storageGate; return operation(); }
  },
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

function loadConsumer(relative, bindings) {
  const consumer = { exports: {} };
  const source = readFileSync(new URL(relative, import.meta.url), 'utf8')
    .replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const code = ts.transpileModule(source, {
    fileName: 'consumer.ts', compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  vm.runInNewContext(code, {
    Date: Clock, Promise, Error, JSON, Number, Math, Set, Map,
    require(name) { assert.ok(name in bindings, `unexpected consumer module ${name}`); return bindings[name]; },
    module: consumer, exports: consumer.exports
  });
  return consumer.exports;
}

const prefs = {
  getSync(key, fallback) { return state.saved[key] ?? fallback; }, hasSync(key) { return key in state.saved; },
  putSync(key, value) { state.saved[key] = value; },
  async flush() { if (state.flushError) { throw new Error('fixture preference storage failure'); } }
};
const { Connection } = loadConsumer('../entry/src/main/ets/client/Connection.ets', {
  '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.NetworkKit': {},
  '@kit.ArkData': { preferences: { getPreferencesSync: () => prefs } },
  './Controller': {}, './ControllerSocket': { ControllerSocket: class { start() {} stop() {} } },
  './CoreClient': core, './Proxies': { flushProxySelections: async () => {} },
  './Traffic': { traffic: { reset() {} } }, '../shared/Runtime': { runtimeMayBeActive: async () => state.active }
});
const runControls = loadConsumer('../entry/src/main/ets/features/home/HomeRunControls.ets', {});

beforeEach(() => {
  Object.assign(state, { now: 1000, started: 0, stopped: 0, status: undefined,
    runtime: { secret: 'fixture-session', stack: 'gvisor', mode: 'rule' },
    receipt: undefined, startError: undefined, stopError: undefined, stopCleans: false,
    active: false, flushError: false, saved: {}, writingRuntime: false,
    runtimeWriteGate: Promise.resolve(), storageGate: Promise.resolve() });
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
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('同会话清理完成允许确认controller关闭后的停止', async () => {
  state.receipt = state.runtime.secret;
  await core.stopCore(context);
});

test('旧会话回执不能把当前会话误判为已停止', async () => {
  state.receipt = 'previous-session';
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('系统停止失败且内核仍运行时传播错误', async () => {
  state.status = ready;
  state.stopError = new Error('fixture system stop rejected');
  await assert.rejects(core.stopCore(context), /fixture system stop rejected/);
});

test('启动初始空快照不能证明系统VPN已销毁', async () => {
  state.status = { ...ready, running: false, tunAttached: false, listenersOpen: false, bootId: '', revision: 0 };
  await assert.rejects(core.stopCore(context), /尚未确认代理已停止/);
});

test('扩展启动前失败后，下一次按钮动作可直接连接', async () => {
  const connection = new Connection();
  connection.restore(context);
  state.startError = new Error('fixture extension start rejected');
  await assert.rejects(connection.connect(context), /fixture extension start rejected/);
  assert.equal(runControls.homeShouldStopRuntime(connection.intent, connection.forward,
    connection.listenersOpen, connection.tunAttached), false);
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
  const files = new Map();
  const runtimeModule = { exports: {} };
  const runtimeBindings = {
    '@kit.CoreFileKit': { fileIo: { access: async path => files.has(path) } },
    './Files': {
      writeTextAsync: async (path, text) => { files.set(path, text); },
      readText: async (path) => files.get(path)
    }
  };
  const runtimeSource = readFileSync(new URL('../entry/src/main/ets/shared/Runtime.ets', import.meta.url), 'utf8');
  const runtimeCode = ts.transpileModule(runtimeSource, {
    fileName: 'Runtime.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  vm.runInNewContext(runtimeCode, {
    require(name) { assert.ok(name in runtimeBindings, `unexpected runtime module ${name}`); return runtimeBindings[name]; },
    module: runtimeModule, exports: runtimeModule.exports, Promise, JSON
  });
  const runtime = runtimeModule.exports;
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

test('探测在异步读盘期间取消后不创建网络请求', async () => {
  let release;
  const storage = new Promise(resolve => { release = resolve; });
  let opened = 0;
  const { RoutedProbeRequest } = loadConsumer('../entry/src/main/ets/client/RoutedProbe.ets', {
    '@kit.BasicServicesKit': {},
    '@kit.NetworkKit': { http: { createHttp() { opened++; return {}; } } },
    '../shared/Runtime': { readRuntime: async () => { await storage; return state.runtime; } }
  });
  const request = new RoutedProbeRequest();
  const pending = request.run(context.filesDir, 'https://example.invalid/', 'GET', 1000, true);
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
