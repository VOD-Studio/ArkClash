// 仅在宿主执行真实数据层源码；系统接口替身用于故障注入，不进入 HAP。
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
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
let updatePreference = true;
let updateDistribution = 'none';
let galleryUpdates = 0;
let saveTarget = '';
const transfers = new Map();
const packageBytes = Buffer.from('synthetic HAP');
const appGallery = {
  UpdateAvailableCode: { LATER_VERSION_EXIST: 1 }, ShowUpdateResultCode: { SHOW_DIALOG_SUCCESS: 0 },
  checkAppUpdate: async () => ({ updateAvailable: 1 }),
  showUpdateDialog: async () => { galleryUpdates++; return 0; }
};
const transfer = { agent: {
  Action: { DOWNLOAD: 1 }, Mode: { FOREGROUND: 1 },
  create: async (_context, options) => {
    const events = new Map();
    const task = { tid: String(transfers.size + 1), options,
      on: (event, callback) => events.set(event, callback),
      start: async () => {},
      emit: (event, value) => events.get(event)?.(value)
    };
    transfers.set(task.tid, task);
    return task;
  },
  remove: async (id) => { transfers.delete(id); }
} };
class FixtureDate extends Date { static now() { return clock.now; } }
class FixtureSocket {
  constructor(route, receive) { this.route = route; this.receive = receive; this.active = false; sockets.push(this); }
  start() { this.active = true; }
  stop() { this.active = false; }
  emit(payload) { this.receive(JSON.stringify(payload)); }
}
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8, READ_WRITE: 16 },
  access: async (file) => { try { await fs.access(file); return true; } catch (error) {
    if (error.code === 'ENOENT') { return false; } throw error;
  } },
  readText: (file) => fs.readFile(file, 'utf8'),
  open: async (file, mode) => {
    const handle = await fs.open(file, mode === io.OpenMode.READ_ONLY ? 'r' : 'w');
    handles.set(handle.fd, handle);
    handle.lock = async () => {};
    return handle;
  },
  stat: (file) => fs.stat(file),
  copyFile: async (source, target) => { await handles.get(target).writeFile(await handles.get(source).readFile()); },
  write: (fd, text) => handles.get(fd).write(text),
  close: async (handle) => { handles.delete(handle.fd); await handle.close(); },
  rename: async (from, to) => { if (failRename) { throw new Error('injected rename failure'); } await fs.rename(from, to); },
  unlink: (file) => fs.unlink(file)
};
const http = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD', POST: 'POST' }, HttpDataType: { STRING: 0 },
  createHttp: () => {
    const request = {
      destroyed: false, settled: false,
      streaming: false, listeners: new Map(),
      on(name, callback) { this.listeners.set(name, callback); },
      off(name) { this.listeners.delete(name); },
      emit(name, value) { this.listeners.get(name)?.(value); },
      requestInStream(url, options) { this.streaming = true; return this.request(url, options); },
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
  console, Date: FixtureDate, Set, Map, JSON, Math, Number, String, Array, Object, Error, Uint8Array, ArrayBuffer,
  RegExp, encodeURIComponent, decodeURIComponent,
  $r: (key) => key,
  setInterval: (callback) => { timers.set(++timerId, callback); return timerId; },
  clearInterval: (id) => timers.delete(id),
  setTimeout: (callback) => { timers.set(++timerId, callback); return timerId; },
  clearTimeout: (id) => timers.delete(id)
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
    if (name === '@kit.AbilityKit') { return { bundleManager: {
      BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
      getBundleInfoForSelf: async () => ({ versionName: '0.5.1', appInfo: { appDistributionType: updateDistribution } })
    } }; }
    if (name === '@kit.AppGalleryKit') { return { updateManager: appGallery }; }
    if (name === '@kit.BasicServicesKit') { return { request: transfer }; }
    if (name === '@kit.CoreFileKit') { return { fileIo: io,
      hash: { hash: async (file) => createHash('sha256').update(await fs.readFile(file)).digest('hex') },
      picker: { DocumentSaveOptions: class {}, DocumentViewPicker: class {
        async save() { return saveTarget === '' ? [] : [saveTarget]; }
      } }
    }; }
    if (name === '@kit.ArkData') { return { preferences: {
      getPreferences: async (_context, options) => options.name === 'app-update' ? {
        get: async () => updatePreference, put: async (_key, value) => { updatePreference = value; }, flush: async () => {}
      } : { getAll: async () => structuredClone(legacyPreferences) }
    } }; }
    if (name === '@kit.NetworkKit') { return { http }; }
    if (name === '@kit.ArkTS') { return {
      url: { URL: { parseURL: (address, base) => new URL(address, base) } },
      util: { TextDecoder: { create: () => {
        const decoder = new TextDecoder();
        return { decodeToString: (bytes, options) => decoder.decode(bytes, options) };
      } } }
    }; }
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
const flush = () => new Promise((resolve) => setImmediate(resolve));
async function activeUpdateTransfer() {
  for (let attempt = 0; attempt < 100; attempt++) {
    const task = transfers.values().next().value;
    if (task) { return task; }
    await flush();
  }
  assert.fail('预期文件下载已开始');
}
function respond(request, payload, code = 200) {
  assert.ok(request && !request.settled, '预期存在一个待返回的请求');
  request.settled = true;
  if (request.streaming) {
    request.emit('headersReceive', { 'status-line': `HTTP/1.1 ${code} Result` });
    if (!request.destroyed) {
      request.emit('dataReceive', new TextEncoder().encode(typeof payload === 'string' ? payload : JSON.stringify(payload)).buffer);
      request.emit('dataEnd');
    }
    request.resolve(code);
  } else {
    request.resolve({ responseCode: code, result: JSON.stringify(payload) });
  }
}
function respondProbe(request, payload = {}, status = 200, revision = 7, bootId = 'host-boot') {
  const command = JSON.parse(request.options.extraData);
  respond(request, { status,
    body: command.bodyMode === 'none' ? '' : typeof payload === 'string' ? payload : JSON.stringify(payload),
    url: command.url, location: '', delay: 37, bootId, revision });
}
function assertCoreRequest(request, target, method, timeout = 5000) {
  const address = new URL(request.url);
  assert.equal(address.origin, 'http://127.0.0.1:19090');
  assert.equal(address.pathname, '/arkclash/probe');
  assert.equal(address.search, '');
  const command = JSON.parse(request.options.extraData);
  assert.equal(command.url, target);
  assert.equal(command.method, method);
  assert.equal(command.timeout, timeout);
  assert.equal(request.options.method, 'POST');
  assert.equal(request.options.usingProxy, false);
  assert.equal(request.options.header.Authorization, `Bearer ${probeToken}`);
  assert.equal(request.options.maxRedirects, 0);
  assert.equal(request.url.includes(probeToken), false);
}
async function makeContext(name) { const filesDir = path.join(sandbox, name); await fs.mkdir(filesDir); return { filesDir }; }

try {
  const { isNewerRelease, AppUpdateState } = load(path.join(ets, 'client/AppUpdate.ets'));
  assert.equal(isNewerRelease('0.9.9', 'v0.10.0'), true);
  assert.equal(isNewerRelease('0.10.0', 'v0.9.9'), false);
  assert.equal(isNewerRelease('0.5.1', 'v0.5.1'), false);
  assert.throws(() => isNewerRelease('0.5.1', 'latest'), /app_update_version/);
  const updateContext = { cacheDir: sandbox };
  const updates = new AppUpdateState();
  await updates.setForeground(updateContext, true);
  assert.equal(timers.size, 1);
  await updates.setForeground(updateContext, false);
  assert.equal(timers.size, 0);
  await updates.setForeground(updateContext, true);
  await updates.setAutomatic(updateContext, false);
  assert.equal(timers.size, 0);
  assert.equal(updatePreference, false);
  await updates.setAutomatic(updateContext, true);
  timers.values().next().value();
  await flush();
  const packageName = 'ArkClash-0.6.0-unsigned.hap';
  const digest = createHash('sha256').update(packageBytes).digest('hex');
  respond(requests.at(-1), { tag_name: 'v0.6.0', assets: [
    { name: packageName, digest: `sha256:${digest}`, size: packageBytes.length },
    { name: 'ArkClash-0.6.0-debug-signed.hap', digest: 'invalid', size: 1 },
    { name: '../other.hap', digest: `sha256:${digest}`, size: 1 }
  ] });
  await flush();
  assert.equal(updates.release.available, 'v0.6.0');
  assert.equal(updates.release.assets.length, 1);
  const asset = updates.release.assets[0];
  assert.equal(asset.url, `https://github.com/VOD-Studio/ArkClash/releases/download/v0.6.0/${packageName}`);
  let download = updates.download(updateContext, asset.name);
  await activeUpdateTransfer();
  await updates.cancel();
  await download;
  assert.equal(updates.phase, 'idle');
  assert.equal(transfers.size, 0);
  download = updates.download(updateContext, asset.name);
  let updateTask = await activeUpdateTransfer();
  await fs.writeFile(updateTask.options.saveas, Buffer.alloc(packageBytes.length));
  updateTask.emit('completed');
  await assert.rejects(download, /app_update_checksum/);
  assert.equal(await io.access(updateTask.options.saveas), false);
  download = updates.download(updateContext, asset.name);
  updateTask = await activeUpdateTransfer();
  await fs.writeFile(updateTask.options.saveas, packageBytes);
  updateTask.emit('completed');
  await download;
  assert.equal(updates.phase, 'ready');
  assert.equal(await updates.save(updateContext), false);
  assert.equal(updates.phase, 'ready');
  saveTarget = path.join(sandbox, packageName);
  assert.equal(await updates.save(updateContext), true);
  assert.deepEqual(await fs.readFile(saveTarget), packageBytes);
  assert.equal(await io.access(updateTask.options.saveas), false);
  updateDistribution = 'app_gallery';
  await updates.check(updateContext);
  assert.equal(updates.release.galleryUpdate, true);
  await updates.install(updateContext);
  assert.equal(galleryUpdates, 1);
  updateDistribution = 'none';
  requests.length = 0;
  timers.clear();
  const runControls = load(path.join(homeSource, 'HomeRunControls.ets'));
  assert.equal(runControls.homeShouldStopRuntime('started', 'preparing', false, false, false, 'running'), true);
  for (const resources of [[true, false, false], [false, true, false], [false, false, true]]) {
    for (const forward of ['failed', 'stopped']) {
      assert.equal(runControls.homeHasPendingCleanup(forward, ...resources, 'running'), true);
      assert.equal(runControls.homeShouldStopRuntime('stopped', forward, ...resources, 'running'), true);
      assert.equal(runControls.homeRunActionLabel('stopped', forward, ...resources, 'running'),
        'app.string.dash_stop_retry');
    }
  }
  for (const host of ['running', 'stopped']) {
    assert.equal(runControls.homeShouldStopRuntime('stopped', 'stopped', false, false, false, host), false);
    assert.equal(runControls.homeRuntimeAppearsStarted('stopped', 'stopped', false, false, false, host), false);
    assert.equal(runControls.homeRunActionLabel('stopped', 'stopped', false, false, false, host),
      'app.string.action_connect');
  }
  assert.equal(runControls.homeRuntimeAppearsStarted('started', 'preparing', false, false, false, 'running'), true);
  assert.equal(runControls.homeHasPendingCleanup('running', true, true, true, 'running'), false);
  assert.equal(runControls.homeRunActionLabel('started', 'running', true, true, true, 'running'),
    'app.string.action_disconnect');
  assert.equal(runControls.homeShouldStopRuntime('stopped', 'failed', false, false, false, 'unknown'), true);
  assert.equal(runControls.homeRunActionLabel('stopped', 'stopped', false, false, false, 'unknown'),
    'app.string.dash_runtime_stop_confirm');
  assert.equal(runControls.homeShouldStopRuntime('started', 'stopped', false, false, false, 'running'), false);
  assert.equal(runControls.homeRunActionLabel('started', 'stopped', false, false, false, 'running'),
    'app.string.action_connect');
  assert.equal(runControls.homeRunActionLabel('stopped', 'failed', false, false, false, 'running'),
    'app.string.dash_stop_retry');
  const fallback = 'app.string.dash_vpn_connect_failed';
  assert.equal(runControls.homeRunFailureMessage('vpn_no_profile', false, fallback), 'app.string.dash_vpn_no_profile');
  assert.equal(runControls.homeRunFailureMessage('vpn_authorization_denied', false, fallback),
    'app.string.dash_vpn_authorization_denied');
  assert.equal(runControls.homeRunFailureMessage('vpn_create_failed', false, fallback),
    'app.string.dash_vpn_create_failed');
  assert.equal(runControls.homeRunFailureMessage('vpn_attach_failed', false, fallback),
    'app.string.dash_vpn_attach_failed');
  assert.equal(runControls.homeRunFailureMessage('vpn_create_failed;vpn_destroy_failed', false, fallback),
    'app.string.dash_cleanup_required');
  assert.equal(runControls.homeRunFailureMessage('conflict', true, fallback), 'app.string.dash_cleanup_required');
  assert.equal(runControls.homeRunFailureMessage('unexpected error', false, fallback), fallback);
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
  const retained = await fs.readFile(documentPath, 'utf8');
  failRename = true;
  const unsaved = reopened.commit({ hideIp: false }, reopened.revision);
  reopened.discardDraft();
  await assert.rejects(unsaved);
  assert.equal(reopened.hasDraft, true);
  assert.equal(reopened.hideIp, true);
  reopened.discardDraft();
  assert.equal(reopened.hasDraft, false);
  assert.equal(reopened.failure, '');
  failRename = false;
  await reopened.retryDraft();
  assert.equal(await fs.readFile(documentPath, 'utf8'), retained);
  legacyPreferences = { serviceLayout: '{broken' };
  const corruptContext = await makeContext('corrupt'); const corrupt = new DashboardSettings();
  await corrupt.load(corruptContext); assert.equal(corrupt.ready, false);
  assert.equal(await io.access(path.join(corruptContext.filesDir, 'dashboard.json')), false);
  assert.equal(legacyPreferences.serviceLayout, '{broken');
  corrupt.discardDraft();
  assert.equal(corrupt.failure, 'read');

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
  assert.equal(traffic.stale, false, '退订但未断开连接时保留最后速率，避免回前台闪成过期');
  socket.emit({ up: 999, down: 999 }); assert.equal(traffic.up, 7);
  traffic.start('/unused', 'card');
  assert.equal(traffic.stale, false, '回前台重新订阅时保留已有速率');
  const resumedSocket = sockets.at(-1);
  clock.now += 200;
  resumedSocket.emit({ up: 42, down: 84, upTotal: 420, downTotal: 840 });
  assert.equal(traffic.up, 42, '重连后的首条速率推送立即发布，不等待 1 秒定时器');
  assert.equal(traffic.down, 84);
  clock.now += 5000; for (const callback of timers.values()) { callback(); }
  assert.equal(traffic.stale, true, '重连后长时间无推送仍应标记过期');
  traffic.stop('card');
  traffic.reset(); assert.equal(traffic.upTotal, 0); assert.equal(traffic.samples.length, 0); assert.equal(traffic.stale, true);

  // 跨整秒边界抖动（如 10.995s -> 12.015s -> 12.990s -> 14.020s）不得被误判为断档或覆写丢点。
  const jitter = new Traffic();
  jitter.start('/unused', 'card');
  const jitterSocket = sockets.at(-1);
  for (const [at, up, down] of [[200995, 100, 200], [202015, 0, 0], [202990, 0, 0], [204020, 300, 400]]) {
    clock.now = at;
    jitterSocket.emit({ up, down });
  }
  assert.equal(jitter.samples.length, 4, '跨整秒抖动应保留全部 4 个连续采样点');
  assert.ok(jitter.samples.every((sample) => sample.available), '正常每秒推送抖动不得插入假断档');
  const jitterGraph = chart.dashboardTrafficGraph(jitter.samples, true, 290, 56);
  assert.equal((jitterGraph.line.match(/M/g) ?? []).length, 1, '连续采样只应绘制一条完整曲线');
  assert.ok(jitterGraph.area.length > 0, '连续曲线应绘制闭合面积填充');
  const firstY = Number(/M[0-9.-]+ ([0-9.-]+)/.exec(jitterGraph.line)?.[1] ?? 56);
  assert.ok(firstY < 56, '0 B/s 基线应保留在底边裁剪线内');
  const orphanGraph = chart.dashboardTrafficGraph([
    { timestamp: 1000, up: 10, down: 10, available: true },
    { timestamp: 2000, up: 0, down: 0, available: false },
    { timestamp: 3000, up: 20, down: 20, available: true }
  ], true, 290, 56);
  assert.equal(orphanGraph.area, '', '孤立单点不应生成零宽面积毛刺');
  jitter.stop('card');

  const duplicate = appendTrafficSample([{ timestamp: 1000, up: 2, down: 3, available: true }],
    { timestamp: 1900, up: 8, down: 9, available: true });
  assert.equal(duplicate.length, 1); assert.equal(duplicate[0].up, 8);

  const checks = load(path.join(ets, 'client/ServiceCheck.ets'));
  assert.equal(checks.serviceReachability(200), 'reachable');
  assert.equal(checks.serviceReachability(403), 'restricted');
  const task = new checks.ServiceCheckTask();
  const probeTarget = 'https://www.google.com/generate_204?first=one&second=two';
  const run = task.run('/unused', [{ id: 'legacy-test', url: probeTarget }], 'route-a', true);
  await flush(); assertCoreRequest(requests.at(-1), probeTarget, 'GET', 10000); respondProbe(requests.at(-1), {}, 403);
  const checked = await run;
  assert.equal(checked[0].reachability, 'restricted'); assert.equal(checked[0].availability, 'unknown');
  assert.equal(checked[0].bootId, 'host-boot'); assert.equal(checked[0].revision, 7);
  const methodRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'legacy-test', url: probeTarget }], 'route-a', true);
  await flush(); respondProbe(requests.at(-1), {}, 405);
  const methodResult = (await methodRun)[0];
  assert.equal(methodResult.httpCode, 405); assert.equal(methodResult.reachability, 'restricted');
  assert.equal(methodResult.availability, 'unknown'); assert.equal(methodResult.failure, '');
  for (const code of [429, 504, 503, 403]) {
    const failedRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'google', url: probeTarget }], 'route-a', true);
    await flush(); respond(requests.at(-1), { message: 'fixture-control-error' }, code);
    if (code === 504) {
      await flush();
      respond(requests.at(-1), { message: 'fixture-control-error' }, code);
    }
    const failed = (await failedRun)[0];
    assert.equal(failed.httpCode, 0);
    assert.equal(failed.controlStatus, code === 504 || code === 503 ? 0 : code);
    assert.equal(failed.availability, code === 504 ? 'timeout' : code === 503 ? 'failed' : 'unknown');
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
  const directRun = new checks.ServiceCheckTask().run('/unused', [{ id: 'legacy-test', url: probeTarget }], 'direct', false);
  await flush(); const directRequest = requests.at(-1);
  assert.equal(directRequest.url, probeTarget); assert.equal(directRequest.options.method, 'GET');
  assert.equal(directRequest.options.header.Authorization, undefined); assert.equal(directRequest.options.usingProxy, false);
  respond(directRequest, {}, 405); const directResult = (await directRun)[0];
  assert.equal(directResult.httpCode, 405); assert.equal(directResult.reachability, 'restricted');
  assert.equal(directResult.availability, 'unknown');
  assert.equal(directResult.routed, false); assert.equal(directResult.bootId, '');

  const claudeRun = new checks.ServiceCheckTask().run('/unused',
    [{ id: 'claude', url: 'https://claude.ai/' }], 'route-a', true);
  await flush();
  const claudeRequest = requests.at(-1);
  assertCoreRequest(claudeRequest, 'https://claude.ai/cdn-cgi/trace', 'GET', 10000);
  assert.match(JSON.parse(claudeRequest.options.extraData).headers['User-Agent'], /Chrome\/120/);
  respondProbe(claudeRequest, 'loc=JP\n');
  const claudeResult = (await claudeRun)[0];
  assert.equal(claudeResult.availability, 'available'); assert.equal(claudeResult.region, 'JP');
  assert.equal(claudeResult.reachability, 'reachable'); assert.equal(claudeResult.delay, 37);

  const chatRun = new checks.ServiceCheckTask().run('/unused',
    [{ id: 'chatgpt', url: 'https://chatgpt.com/' }], 'route-a', true);
  await flush(); respondProbe(requests.at(-1), 'Request is not allowed. Please try again later.', 403);
  await flush(); respondProbe(requests.at(-1), 'loc=JP\n');
  await flush(); respondProbe(requests.at(-1), '{}');
  const chatResult = (await chatRun)[0];
  assert.equal(chatResult.httpCode, 403); assert.equal(chatResult.availability, 'available');
  assert.equal(chatResult.reachability, 'reachable'); assert.equal(chatResult.region, 'JP');

  const changingChat = new checks.ServiceCheckTask().run('/unused',
    [{ id: 'chatgpt', url: 'https://chatgpt.com/' }], 'route-a', true);
  const changingChatRejected = assert.rejects(changingChat, (error) => error.reason === 'routeChanged');
  await flush(); respondProbe(requests.at(-1), 'Request is not allowed. Please try again later.', 403);
  await flush(); const traceBeforeChange = requests.at(-1);
  respondProbe(traceBeforeChange, 'loc=JP\n', 200, 8);
  await changingChatRejected; await flush();
  assert.equal(requests.at(-1), traceBeforeChange, '多步检测切换路由后不能继续或发布混合出口结果');

  const { DashboardServiceState } = load(path.join(homeSource, 'DashboardServiceState.ets'));
  const state = new DashboardServiceState(); state.observe('/unused', 'route-a', true, true, []);
  const oldRun = state.run(['google']); await flush(); const oldRequest = requests.at(-1);
  state.observe('/unused', 'route-b', true, true, []); assert.equal(oldRequest.destroyed, true);
  const newRun = state.run(['google']); await flush(); const newRequest = requests.at(-1);
  respondProbe(oldRequest); respondProbe(newRequest); await Promise.all([oldRun, newRun]);
  assert.equal(state.results.google.route, 'route-b');
  const cancelledRun = state.run(['google']); await flush(); const cancelledRequest = requests.at(-1);
  state.observe('/unused', 'route-b', true, false, []); respondProbe(cancelledRequest, {}, 500); await cancelledRun;
  assert.equal(cancelledRequest.destroyed, true); assert.equal(state.results.google.httpCode, 200);
  state.observe('/unused', 'route-b', true, true, []);
  const obsoleteRun = state.run(['google']); await flush(); respond(requests.at(-1), { message: 'route changed' }, 409);
  await obsoleteRun; assert.equal(state.failed, true); assert.equal(Object.keys(state.results).length, 0);

  const automatic = new DashboardServiceState();
  const beforeAutomatic = requests.length;
  automatic.observe('/unused', 'auto-a', true, false, ['google']);
  await flush(); assert.equal(requests.length, beforeAutomatic);
  automatic.observe('/unused', 'auto-a', true, true, ['google']);
  await flush(); const automaticGoogle = requests.at(-1);
  assertCoreRequest(automaticGoogle, 'https://www.google.com/generate_204', 'GET', 10000);
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github']);
  await flush(); assert.equal(requests.at(-1), automaticGoogle);
  respondProbe(automaticGoogle, {}, 204); await flush();
  const automaticGithub = requests.at(-1);
  assertCoreRequest(automaticGithub, 'https://github.com/', 'GET', 10000);
  assert.equal(automatic.results.google.httpCode, 204);
  automatic.observe('/unused', 'auto-a', true, true, ['google']);
  assert.equal(automaticGithub.destroyed, true);
  respondProbe(automaticGithub, {}, 403); await flush();
  assert.equal(automatic.results.github, undefined);
  automatic.observe('/unused', 'auto-a', true, false, ['google']);
  automatic.observe('/unused', 'auto-a', true, true, ['google']);
  await flush(); assert.equal(requests.at(-1), automaticGithub);

  clock.now += 60001;
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github']);
  await flush();
  const expiredGoogle = requests.at(-2); const expiredGithub = requests.at(-1);
  assertCoreRequest(expiredGoogle, 'https://www.google.com/generate_204', 'GET', 10000);
  assertCoreRequest(expiredGithub, 'https://github.com/', 'GET', 10000);
  respondProbe(expiredGoogle, {}, 204); respond(expiredGithub, {}, 429); await flush();
  assert.equal(automatic.results.github.reachability, 'notChecked');
  assert.equal(automatic.results.github.failure, 'capacity');
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github']);
  await flush(); assert.equal(requests.at(-1), expiredGithub);
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github', 'youtube']);
  await flush(); const cancelledAutomatic = requests.at(-1);
  automatic.cancel();
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github']);
  automatic.observe('/unused', 'auto-a', true, true, ['google', 'github', 'youtube']);
  respondProbe(cancelledAutomatic); await flush();
  assert.equal(cancelledAutomatic.destroyed, true);
  assert.equal(automatic.results.youtube, undefined);
  assert.equal(requests.at(-1), cancelledAutomatic);

  automatic.observe('/unused', 'auto-b', true, true, ['google']);
  await flush(); const routeBRequest = requests.at(-1);
  automatic.observe('/unused', 'auto-c', true, true, ['google']);
  await flush(); const routeCRequest = requests.at(-1);
  respondProbe(routeBRequest, {}, 200); respondProbe(routeCRequest, {}, 403); await flush();
  assert.equal(routeBRequest.destroyed, true);
  assert.equal(automatic.results.google.route, 'auto-c');
  assert.equal(automatic.results.google.httpCode, 403);
  assert.equal(automatic.results.google.availability, 'restricted');
  automatic.observe('/unused', 'auto-d', true, true, ['google', 'github']);
  await flush(); const rejectedBatch = requests.slice(-2);
  respond(rejectedBatch[0], {}, 409); await flush();
  respondProbe(rejectedBatch[1]); await flush();
  assert.equal(automatic.failed, true);
  assert.deepEqual(plain(automatic.results), {});
  assert.equal(rejectedBatch[1].destroyed, true);
  assert.equal(requests.at(-1), rejectedBatch[1]);
  automatic.observe('/unused', 'auto-d', true, false, ['google']);

  const suspendedServices = new DashboardServiceState();
  suspendedServices.observe('/unused', 'suspend-a', true, true, ['google']);
  await flush(); respondProbe(requests.at(-1), {}, 204); await flush();
  assert.equal(suspendedServices.results.google.httpCode, 204);
  suspendedServices.suspend();
  suspendedServices.observe('/unused', 'suspend-a', true, true, ['google', 'github']);
  await flush();
  assert.equal(suspendedServices.results.google.httpCode, 204, '挂起再挂载保留同路由结果');
  const suspendedGithub = requests.at(-1);
  assertCoreRequest(suspendedGithub, 'https://github.com/', 'GET', 10000);
  respondProbe(suspendedGithub, {}, 200); await flush();
  assert.equal(suspendedServices.results.github.httpCode, 200, '挂起不锁死自动检测');
  suspendedServices.suspend();

  const exits = load(path.join(ets, 'client/ExitIp.ets'));
  assert.equal(exits.validExitAddress('2001:db8::1'), true); assert.equal(exits.validExitAddress(':::'), false);
  assert.equal(exits.validExitAddress('999.1.2.3'), false);
  const { parseExitIpQuality } = load(path.join(ets, 'client/ExitIpQuality.ets'));
  const ipQuality = (body, ip = '198.51.100.2') => parseExitIpQuality(JSON.stringify(body), ip, 'test');
  assert.equal(ipQuality({ ip: '198.51.100.3', type: 'isp' }), undefined);
  assert.equal(ipQuality({ ip: '198.51.100.2', is_proxy: false }), undefined);
  assert.equal(parseExitIpQuality('{', '198.51.100.2', 'test'), undefined);
  assert.equal(ipQuality({ ip: '198.51.100.2', type: 'isp', is_vpn: true }).level, 'good');
  assert.equal(ipQuality({ ip: '198.51.100.2', company: { type: 'hosting' } }).level, 'normal');
  assert.equal(ipQuality({ ip: '198.51.100.2', is_mobile: true }).type, 'mobile');
  assert.equal(ipQuality({ ip: '198.51.100.2', type: 'government' }).type, 'business');
  assert.equal(ipQuality({ ip: '198.51.100.2', type: 'isp', privacy: { is_abuser: true } }).level, 'risky');
  assert.equal(ipQuality({ ip: '2001:0db8:0:0:0:0:0:1', type: 'isp' }, '2001:db8::1').type, 'residential');
  assert.equal(ipQuality({ ip: '2001:db8::2', type: 'isp' }, '2001:db8::1'), undefined);
  const exit = new exits.ExitIpProbe(); exit.observe('/unused', 'route-a', true, true);
  await flush(); const oldExitRequest = requests.at(-1);
  exit.observe('/unused', 'route-b', true, true); await flush(); const newExitRequest = requests.at(-1);
  respondProbe(oldExitRequest, { ip: '192.0.2.1' });
  respondProbe(newExitRequest, { ip: '198.51.100.2', country_code: 'US' });
  await flush(); assert.equal(oldExitRequest.destroyed, true);
  assert.equal(exit.result.route, 'route-b'); assert.equal(exit.result.ip, '198.51.100.2');
  assertCoreRequest(newExitRequest, 'https://ipwho.is/', 'GET'); assert.equal(exit.result.bootId, 'host-boot');
  assert.equal(exit.qualityBusy, true); assert.equal(exit.quality, undefined);
  assertCoreRequest(requests.at(-1), 'https://ident.me/json', 'GET');
  respondProbe(requests.at(-1), { ip: '198.51.100.2', type: 'isp' }); await flush();
  assert.equal(exit.quality.type, 'residential'); assert.equal(exit.quality.level, 'good');
  assert.equal(exit.qualityBusy, false); assert.equal(exit.busy, false);
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
  const directQualityRequest = requests.at(-1);
  assert.equal(directQualityRequest.options.header.Authorization, undefined);
  respond(directQualityRequest, { ip: '203.0.113.9', type: 'hosting' }); await flush();
  assert.equal(exit.quality.level, 'normal');
  exit.observe('/unused', 'direct-again', false, true); await flush();
  const cachedGeoRequest = requests.at(-1); respond(cachedGeoRequest, { ip: '203.0.113.9' }); await flush();
  assert.equal(exit.quality.level, 'normal'); assert.equal(exit.busy, false);
  assert.equal(requests.at(-1), cachedGeoRequest);
  const refreshQuality = exit.refresh(); await flush();
  respond(requests.at(-1), { ip: '203.0.113.9' }); await flush();
  respond(requests.at(-1), { ip: '203.0.113.9', type: 'hosting', is_tor: true }); await refreshQuality;
  assert.equal(exit.quality.level, 'risky');
  exit.observe('/unused', 'next-route', false, true); await flush();
  respond(requests.at(-1), { ip: '203.0.113.10' }); await flush();
  const obsoleteQualityRequest = requests.at(-1);
  exit.observe('/unused', 'last-route', false, true); await flush();
  assert.equal(obsoleteQualityRequest.destroyed, true);
  respond(requests.at(-1), { ip: '203.0.113.11' }); await flush();
  const lastQualityRequest = requests.at(-1);
  respond(obsoleteQualityRequest, { ip: '203.0.113.10', type: 'isp' }); await flush();
  assert.equal(exit.quality, undefined);
  respond(lastQualityRequest, { ip: '203.0.113.11' }); await flush();
  assert.equal(requests.at(-1).url, 'https://iplocate.io/api/lookup/203.0.113.11');
  respond(requests.at(-1), { ip: '203.0.113.11', company: { type: 'business' } }); await flush();
  assert.equal(exit.quality.ip, '203.0.113.11'); assert.equal(exit.quality.type, 'business');
  const cancelledQuality = exit.refresh(); await flush();
  respond(requests.at(-1), { ip: '203.0.113.11' }); await flush();
  const hiddenQualityRequest = requests.at(-1); exit.observe('/unused', 'last-route', false, false);
  respond(hiddenQualityRequest, { ip: '203.0.113.11', type: 'hosting' }); await cancelledQuality;
  assert.equal(hiddenQualityRequest.destroyed, true); assert.equal(exit.quality, undefined);

  const coordinatedServices = new DashboardServiceState();
  const coordinatedExit = new exits.ExitIpProbe();
  const coordinatedStart = requests.length;
  const coordinatedIds = ['google', 'github', 'youtube'];
  coordinatedServices.observe('/unused', 'before-switch', true, true, coordinatedIds);
  coordinatedExit.observe('/unused', 'before-switch', true, true);
  await flush();
  const retiringRequests = requests.slice(coordinatedStart);
  assert.equal(retiringRequests.length, 4);
  coordinatedServices.observe('/unused', 'discarded-switch', true, true, coordinatedIds);
  coordinatedExit.observe('/unused', 'after-switch', true, true);
  await flush();
  assert.equal(requests.length, coordinatedStart + 4, '取消尚未返回时不得抢占内核的执行名额');
  coordinatedServices.observe('/unused', 'discarded-switch', true, false, coordinatedIds);
  coordinatedServices.observe('/unused', 'after-switch', true, true, coordinatedIds);
  await flush();
  const bypass = new checks.ServiceCheckTask().run('/unused',
    [{ id: 'legacy-test', url: probeTarget }], 'stopped', false);
  await flush();
  const bypassRequest = requests.at(-1);
  assert.equal(bypassRequest.url, probeTarget);
  respond(bypassRequest, {}, 204);
  assert.equal((await bypass)[0].httpCode, 204, '停止后的直连不能被旧内核请求阻塞');
  for (const request of retiringRequests) {
    assert.equal(request.destroyed, true);
    respondProbe(request, { ip: '192.0.2.4' });
  }
  await flush();
  const admittedRequests = requests.slice(coordinatedStart + 5);
  assert.equal(admittedRequests.length, 4, '已取消的排队任务不得再次发送');
  for (const request of admittedRequests) {
    respondProbe(request, { ip: '198.51.100.7', country_code: 'US' });
  }
  await flush();
  respondProbe(requests.at(-1), { ip: '198.51.100.7', type: 'isp' });
  await flush();
  for (const id of coordinatedIds) {
    assert.equal(coordinatedServices.results[id].route, 'after-switch');
    assert.equal(coordinatedServices.results[id].reachability, 'reachable');
  }
  assert.equal(coordinatedExit.result.ip, '198.51.100.7');
  assert.equal(coordinatedExit.result.route, 'after-switch');
  assert.equal(coordinatedExit.quality.level, 'good');
  assert.equal(coordinatedExit.busy, false);
  coordinatedServices.observe('/unused', 'after-switch', true, false, coordinatedIds);
  coordinatedExit.observe('/unused', 'after-switch', true, false);

  const { MemoryStats, UiMemoryStats } = load(path.join(ets, 'client/Stats.ets'));
  const coreMemory = new MemoryStats();
  coreMemory.start('/unused', 'dashboard-memory');
  sockets.at(-1).emit({ inuse: 64 * 1024 * 1024 });
  assert.equal(coreMemory.received, true); assert.equal(coreMemory.coreBytes, 64 * 1024 * 1024);
  coreMemory.stop('dashboard-memory');
  assert.equal(coreMemory.received, true, '隐藏退订不清空核心内存缓存');
  coreMemory.reset();
  assert.equal(coreMemory.received, false); assert.equal(coreMemory.coreBytes, 0);
  const memory = new UiMemoryStats(); await memory.refresh();
  assert.equal(memory.pssSwapBytes, 11 * 1024); assert.equal(memory.rssBytes, 17 * 1024);
  console.log('dashboard host: defaults, lossless migration, atomic failure, conflict recovery, traffic gaps, cancellation and route isolation passed');
} finally {
  for (const handle of handles.values()) { await handle.close(); }
  await fs.rm(sandbox, { recursive: true, force: true });
}
