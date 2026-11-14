// 仅在宿主执行真实数据层源码；系统接口替身用于故障注入，不进入 HAP。
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const compiler = process.argv[2] ?? process.env.ARKCLASH_TYPESCRIPT ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';
assert.ok(existsSync(compiler), '请将 TypeScript 编译器路径作为第一个参数传入');
const ts = require(compiler);
const ets = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../entry/src/main/ets');
const homeSource = path.join(ets, 'features/home');
const sandbox = await fs.mkdtemp(path.join(tmpdir(), 'arkclash-dashboard-host-'));
const clock = { now: 100000 };
const timers = new Map();
const sockets = [];
const requests = [];
const handles = new Map();
let timerId = 0;
let legacyPreferences = {};
let failRename = false;
class FixtureDate extends Date { static now() { return clock.now; } }
class FixtureSocket {
  constructor(route, receive) { this.route = route; this.receive = receive; this.active = false; sockets.push(this); }
  start() { this.active = true; }
  stop() { this.active = false; }
  emit(payload) { this.receive(JSON.stringify(payload)); }
}
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  access: async (file) => { try { await fs.access(file); return true; } catch (error) {
    if (error.code === 'ENOENT') { return false; } throw error;
  } },
  readText: (file) => fs.readFile(file, 'utf8'),
  open: async (file) => { const handle = await fs.open(file, 'w'); handles.set(handle.fd, handle); return handle; },
  write: (fd, text) => handles.get(fd).write(text),
  close: async (handle) => { handles.delete(handle.fd); await handle.close(); },
  rename: async (from, to) => { if (failRename) { throw new Error('injected rename failure'); } await fs.rename(from, to); },
  unlink: (file) => fs.unlink(file)
};
const http = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD' }, HttpDataType: { STRING: 0 },
  createHttp: () => {
    const request = {
      destroyed: false, settled: false,
      request(url, options) {
        this.url = url; this.options = options;
        return new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
      },
      destroy() { this.destroyed = true; }
    };
    requests.push(request); return request;
  }
};
const probeToken = 'probe-unit-fixture';
const runtimeFixture = { CONTROLLER_ADDRESS: '127.0.0.1:19090', readRuntime: async () => ({ secret: probeToken }) };
const modules = new Map();
const context = vm.createContext({
  console, Date: FixtureDate, Set, Map, JSON, Math, Number, String, Array, Object, Error,
  $r: (key) => key,
  setInterval: (callback) => { timers.set(++timerId, callback); return timerId; },
  clearInterval: (id) => timers.delete(id)
});
function load(file) {
  const absolute = path.resolve(file);
  if (modules.has(absolute)) { return modules.get(absolute).exports; }
  const record = { exports: {} }; modules.set(absolute, record);
  const source = readFileSync(absolute, 'utf8').replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, fileName: absolute + '.ts'
  }).outputText;
  const scopedRequire = (name) => {
    if (name === '@kit.AbilityKit' || name === '@kit.BasicServicesKit') { return {}; }
    if (name === '@kit.CoreFileKit') { return { fileIo: io }; }
    if (name === '@kit.ArkData') { return { preferences: {
      getPreferences: async () => ({ getAll: async () => structuredClone(legacyPreferences) })
    } }; }
    if (name === '@kit.NetworkKit') { return { http }; }
    if (name === '@kit.PerformanceAnalysisKit') { return { hidebug: {
      getAppNativeMemInfoAsync: async () => ({ pss: 11n, rss: 17n })
    } }; }
    if (name.endsWith('/Runtime')) { return runtimeFixture; }
    if (name.endsWith('/Controller') || name === './Controller') { throw new Error('探测不得查询代理端口'); }
    if (name.endsWith('/ControllerSocket') || name === './ControllerSocket') { return { ControllerSocket: FixtureSocket }; }
    return load(path.resolve(path.dirname(absolute), name + '.ets'));
  };
  new vm.Script(`(function(require,module,exports){${compiled}\n})`, { filename: absolute })
    .runInContext(context)(scopedRequire, record, record.exports);
  return record.exports;
}
const plain = (subject) => JSON.parse(JSON.stringify(subject));
const flush = async () => { for (let index = 0; index < 20; index++) { await Promise.resolve(); } };
function respond(request, payload, code = 200) {
  assert.ok(request && !request.settled, '预期存在一个待返回的请求');
  request.settled = true; request.resolve({ responseCode: code, result: JSON.stringify(payload) });
}
function respondProbe(request, payload = {}, status = 200, revision = 7, bootId = 'host-boot') {
  const method = new URL(request.url).searchParams.get('method');
  respond(request, { status, body: method === 'HEAD' ? '' : JSON.stringify(payload), bootId, revision });
}
function assertCoreRequest(request, target, method) {
  const address = new URL(request.url);
  assert.equal(address.origin, 'http://127.0.0.1:19090');
  assert.equal(address.pathname, '/arkclash/probe');
  assert.equal(address.searchParams.get('url'), target);
  assert.equal(address.searchParams.get('method'), method);
  assert.equal(address.searchParams.get('timeout'), '5000');
  assert.equal(request.options.method, 'GET');
  assert.equal(request.options.usingProxy, false);
  assert.equal(request.options.header.Authorization, `Bearer ${probeToken}`);
  assert.equal(request.options.maxRedirects, 0);
  assert.equal(request.url.includes(probeToken), false);
}
async function makeContext(name) { const filesDir = path.join(sandbox, name); await fs.mkdir(filesDir); return { filesDir }; }

try {
  const runControls = load(path.join(homeSource, 'HomeRunControls.ets'));
  assert.equal(runControls.homeShouldStopRuntime('started', 'preparing', false, false, 'running'), true);
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'failed', true, false, 'running'), true);
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'failed', false, true, 'running'), true);
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'failed', false, false, 'stopped'), false);
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'stopped', false, false, 'stopped'), false);
  assert.equal(runControls.homeRunActionLabel('stopped', 'failed', false, true, 'running'), 'app.string.dash_stop_retry');
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'failed', false, false, 'unknown'), true);
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'stopped', false, false, 'unknown'), true);
  assert.equal(runControls.homeRuntimeAppearsStarted('stopped', 'failed', false, false), false);
  assert.equal(runControls.homeRuntimeAppearsStarted('stopped', 'stopped', false, false), false);
  assert.equal(runControls.homeRuntimeAppearsStarted('started', 'preparing', false, false), true);
  assert.equal(runControls.homeRuntimeAppearsStarted('stopped', 'failed', false, true), true);
  assert.equal(runControls.homeRunActionLabel('stopped', 'failed', false, false, 'unknown'),
    'app.string.dash_runtime_stop_confirm');
  const layout = load(path.join(homeSource, 'DashboardLayout.ets'));
  const services = load(path.join(homeSource, 'Services.ets'));
  const { DashboardSettings } = load(path.join(homeSource, 'DashboardSettings.ets'));
  const freshContext = await makeContext('fresh');
  const fresh = new DashboardSettings(); await fresh.load(freshContext);
  assert.equal(fresh.ready, true);
  assert.deepEqual(plain(fresh.cards), ['status', 'speed', 'mode', 'profile', 'groups']);
  assert.equal(fresh.services.length, 13);
  assert.equal(fresh.services.filter((slot) => slot.visible).length, 13);
  assert.deepEqual(plain(fresh.services.slice(0, 2).map((slot) => slot.id)), ['google', 'github']);
  await fresh.commit({ cards: ['speed', 'groups'] }, fresh.revision);
  assert.deepEqual(plain(fresh.cards), ['status', 'speed', 'groups']);
  assert.deepEqual(plain(layout.movedDashboardCards(fresh.cards, 0, 2)), ['speed', 'groups', 'status']);

  const legacyIds = ['google', 'youtube', 'github', 'telegram', 'x', 'instagram', 'netflix', 'spotify', 'wikipedia',
    'reddit', 'discord', 'tiktok', 'chatgpt', 'claude', 'gemini', 'perplexity', 'deepseek', 'poe', 'huggingface',
    'bilibili', 'baidu', 'netease', 'future-id'];
  const oldSlots = legacyIds.map((id, index) => ({ id, visible: index % 2 === 0, drawer: { custom: index } }));
  legacyPreferences = { serviceLayout: JSON.stringify(oldSlots), drawerOptions: { untouched: true }, hideIp: true };
  const legacyContext = await makeContext('legacy');
  const migrated = new DashboardSettings(); await migrated.load(legacyContext);
  assert.equal(migrated.ready, true);
  assert.deepEqual(plain(migrated.cards), plain(layout.LEGACY_DASHBOARD_CARDS));
  assert.deepEqual(plain(migrated.services.slice(0, oldSlots.length).map((slot) => slot.id)), legacyIds);
  assert.equal(migrated.services.find((slot) => slot.id === 'youtube').visible, false);
  assert.equal(migrated.services.find((slot) => slot.id === 'future-id').legacy, true);
  const before = JSON.parse(await fs.readFile(path.join(legacyContext.filesDir, 'dashboard.json'), 'utf8'));
  assert.deepEqual(before.legacyPreferences, legacyPreferences);
  const reversed = migrated.services.slice().reverse();
  await migrated.commit({ services: reversed }, migrated.revision);
  assert.deepEqual(plain(services.encodeServiceSlots(migrated.services)).find((slot) => slot.id === 'future-id').drawer,
    { custom: 22 });
  const reopened = new DashboardSettings(); await reopened.load(legacyContext);
  assert.equal(reopened.services.length, migrated.services.length);
  assert.equal(reopened.hideIp, true);
  await assert.rejects(reopened.commit({ services: reopened.services.map((slot) => ({ ...slot, visible: false })) },
    reopened.revision));
  assert.ok(reopened.services.some((slot) => slot.visible));

  const documentPath = path.join(legacyContext.filesDir, 'dashboard.json');
  const external = JSON.parse(await fs.readFile(documentPath, 'utf8'));
  external.revision++; external.futureField = { keep: true };
  await fs.writeFile(documentPath, JSON.stringify(external));
  await assert.rejects(reopened.commit({ cards: ['status', 'memory'] }, reopened.revision));
  assert.equal(reopened.failure, 'conflict'); assert.equal(reopened.hasDraft, true);
  await reopened.retryDraft();
  assert.deepEqual(plain(reopened.cards), ['status', 'memory']);
  assert.deepEqual(JSON.parse(await fs.readFile(documentPath, 'utf8')).futureField, { keep: true });
  const stable = await fs.readFile(documentPath, 'utf8');
  failRename = true;
  await assert.rejects(reopened.commit({ cards: ['status', 'services'] }, reopened.revision));
  assert.equal(await fs.readFile(documentPath, 'utf8'), stable);
  assert.deepEqual(plain(reopened.cards), ['status', 'memory']);
  failRename = false; await reopened.retryDraft();
  assert.deepEqual(plain(reopened.cards), ['status', 'services']);
  legacyPreferences = { serviceLayout: '{broken' };
  const corruptContext = await makeContext('corrupt'); const corrupt = new DashboardSettings();
  await corrupt.load(corruptContext); assert.equal(corrupt.ready, false);
  assert.equal(await io.access(path.join(corruptContext.filesDir, 'dashboard.json')), false);
  assert.equal(legacyPreferences.serviceLayout, '{broken');

  const { Traffic, appendTrafficSample, HISTORY_SIZE } = load(path.join(ets, 'client/Traffic.ets'));
  const traffic = new Traffic(); traffic.start('/unused', 'shell'); traffic.start('/unused', 'card');
  const socket = sockets.at(-1);
  for (let index = 0; index < 35; index++) {
    clock.now += 1000; socket.emit({ up: index, down: index * 2, upTotal: index * 10, downTotal: index * 20 });
    for (const callback of timers.values()) { callback(); }
  }
  assert.equal(traffic.samples.length, HISTORY_SIZE); assert.equal(HISTORY_SIZE, 30);
  traffic.stop('shell'); assert.equal(socket.active, true);
  clock.now += 5000; for (const callback of timers.values()) { callback(); }
  assert.equal(traffic.stale, true);
  socket.emit({ up: 7, down: 11 }); for (const callback of timers.values()) { callback(); }
  assert.ok(traffic.samples.some((sample) => !sample.available));
  const chart = load(path.join(homeSource, 'TrafficChart.ets'));
  assert.ok((chart.dashboardTrafficPath(traffic.samples, true, 290, 56).match(/M/g) ?? []).length >= 2);
  traffic.stop('card'); assert.equal(socket.active, false); assert.equal(timers.size, 0);
  socket.emit({ up: 999, down: 999 }); assert.equal(traffic.up, 7);
  traffic.reset(); assert.equal(traffic.upTotal, 0); assert.equal(traffic.samples.length, 0);
  const duplicate = appendTrafficSample([{ timestamp: 1000, up: 2, down: 3, available: true }],
    { timestamp: 1900, up: 8, down: 9, available: true });
  assert.equal(duplicate.length, 1); assert.equal(duplicate[0].up, 8);

  const checks = load(path.join(ets, 'client/ServiceCheck.ets'));
  assert.equal(checks.serviceReachability(200), 'reachable');
  assert.equal(checks.serviceReachability(403), 'restricted');
  const task = new checks.ServiceCheckTask();
  const probeTarget = 'https://www.google.com/generate_204?first=one&second=two';
  const run = task.run('/unused', [{ id: 'google', url: probeTarget }], 'route-a', true);
  await flush(); assertCoreRequest(requests.at(-1), probeTarget, 'HEAD'); respondProbe(requests.at(-1), {}, 403);
  const checked = await run;
  assert.equal(checked[0].reachability, 'restricted'); assert.equal(checked[0].availability, 'unknown');
  assert.equal(checked[0].bootId, 'host-boot'); assert.equal(checked[0].revision, 7);
  for (const code of [429, 504, 503, 403]) {
    const failedRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'google', url: probeTarget }], 'route-a', true);
    await flush(); respond(requests.at(-1), { message: 'fixture-control-error' }, code);
    const failed = (await failedRun)[0];
    assert.equal(failed.httpCode, 0); assert.equal(failed.controlStatus, code);
    assert.equal(failed.availability, 'unknown');
    assert.equal(failed.failure, code === 429 ? 'capacity' : code === 504 ? 'timeout' : code === 503 ? 'transport' : 'controller');
    if (code === 429) { assert.equal(failed.reachability, 'notChecked'); }
  }
  const changedRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'google', url: probeTarget }], 'route-a', true);
  const changedFailure = assert.rejects(changedRun, (error) => error.reason === 'routeChanged');
  await flush(); respond(requests.at(-1), { message: 'route changed' }, 409); await changedFailure;
  const mixedRun = new checks.ServiceCheckTask().run('/unused', [
    { id: 'google', url: probeTarget }, { id: 'github', url: 'https://github.com/' }
  ], 'route-a', true);
  const mixedFailure = assert.rejects(mixedRun, (error) => error.reason === 'routeChanged');
  await flush(); respondProbe(requests.at(-2), {}, 200, 7); respondProbe(requests.at(-1), {}, 200, 8); await mixedFailure;
  const directRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'google', url: probeTarget }], 'direct', false);
  await flush(); const directRequest = requests.at(-1);
  assert.equal(directRequest.url, probeTarget); assert.equal(directRequest.options.method, 'HEAD');
  assert.equal(directRequest.options.header.Authorization, undefined); assert.equal(directRequest.options.usingProxy, false);
  respond(directRequest, {}, 403); const directResult = (await directRun)[0];
  assert.equal(directResult.httpCode, 403); assert.equal(directResult.routed, false); assert.equal(directResult.bootId, '');
  const { DashboardServiceState } = load(path.join(homeSource, 'DashboardServiceState.ets'));
  const state = new DashboardServiceState(); state.observe('/unused', 'route-a', true, true);
  const oldRun = state.run(['google']); await flush(); const oldRequest = requests.at(-1);
  state.observe('/unused', 'route-b', true, true); assert.equal(oldRequest.destroyed, true);
  const newRun = state.run(['google']); await flush(); const newRequest = requests.at(-1);
  respondProbe(oldRequest); respondProbe(newRequest); await Promise.all([oldRun, newRun]);
  assert.equal(state.results.google.route, 'route-b');
  const cancelledRun = state.run(['google']); await flush(); const cancelledRequest = requests.at(-1);
  state.observe('/unused', 'route-b', true, false); respondProbe(cancelledRequest, {}, 500); await cancelledRun;
  assert.equal(cancelledRequest.destroyed, true); assert.equal(state.results.google.httpCode, 200);
  state.observe('/unused', 'route-b', true, true);
  const obsoleteRun = state.run(['google']); await flush(); respond(requests.at(-1), { message: 'route changed' }, 409);
  await obsoleteRun; assert.equal(state.failed, true); assert.equal(Object.keys(state.results).length, 0);

  const exits = load(path.join(ets, 'client/ExitIp.ets'));
  assert.equal(exits.validExitAddress('2001:db8::1'), true); assert.equal(exits.validExitAddress(':::'), false);
  assert.equal(exits.validExitAddress('999.1.2.3'), false);
  const exit = new exits.ExitIpProbe(); exit.observe('/unused', 'route-a', true, true);
  await flush(); const oldExitRequest = requests.at(-1);
  exit.observe('/unused', 'route-b', true, true); await flush(); const newExitRequest = requests.at(-1);
  respondProbe(oldExitRequest, { ip: '192.0.2.1' });
  respondProbe(newExitRequest, { ip: '198.51.100.2', country_code: 'US' });
  await flush(); assert.equal(oldExitRequest.destroyed, true);
  assert.equal(exit.result.route, 'route-b'); assert.equal(exit.result.ip, '198.51.100.2');
  assertCoreRequest(newExitRequest, 'https://ipwho.is/', 'GET'); assert.equal(exit.result.bootId, 'host-boot');
  const retry = exit.refresh(); await flush(); respondProbe(requests.at(-1), {}, 500);
  await flush(); respondProbe(requests.at(-1), { success: false }); await retry;
  assert.equal(exit.failed, true); assert.equal(exit.stale, true); assert.equal(exit.result.ip, '198.51.100.2');
  const obsoleteExit = exit.refresh(); await flush(); respond(requests.at(-1), { message: 'route changed' }, 409);
  await obsoleteExit; assert.equal(exit.failure, 'routeChanged'); assert.equal(exit.result, undefined);
  exit.observe('/unused', 'direct', false, true); await flush(); const directExitRequest = requests.at(-1);
  assert.equal(directExitRequest.url, 'https://ipwho.is/');
  assert.equal(directExitRequest.options.header.Authorization, undefined); assert.equal(directExitRequest.options.usingProxy, false);
  respond(directExitRequest, { ip: '203.0.113.9' }); await flush();
  assert.equal(exit.result.ip, '203.0.113.9'); assert.equal(exit.result.routed, false);
  const { UiMemoryStats } = load(path.join(ets, 'client/Stats.ets'));
  const memory = new UiMemoryStats(); await memory.refresh();
  assert.equal(memory.pssSwapBytes, 11 * 1024); assert.equal(memory.rssBytes, 17 * 1024);
  console.log('dashboard host: defaults, lossless migration, atomic failure, conflict recovery, traffic gaps, cancellation and route isolation passed');
} finally {
  for (const handle of handles.values()) { await handle.close(); }
  await fs.rm(sandbox, { recursive: true, force: true });
}
