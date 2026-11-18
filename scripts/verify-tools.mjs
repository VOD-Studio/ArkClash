// 只隔离平台传输、preferences、运行凭据文件和时钟；回归执行真实产品模块。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const etsDir = fileURLToPath(new URL('../entry/src/main/ets/', import.meta.url));
const plain = data => JSON.parse(JSON.stringify(data));

export function createToolsHarness() {
  let now = Date.parse('2026-01-01T00:00:00Z');
  let nextTimer = 0;
  const timers = new Map();
  const modules = new Map();
  const sockets = [];
  const requests = [];
  const tracked = new Set();
  const controls = {
    preferences: new Map(), preferenceCalls: [], preferenceFlushFailures: 0,
    preferenceGetGate: undefined, preferenceFlushGate: undefined,
    preferenceGetError: false, preferenceFlushError: false, beforePreferenceFlush: undefined,
    actionGate: undefined, actionStatus: 204, actionMessage: '', actionError: false,
    connectError: false, connectCreated: true, runtimeGate: undefined, runtimeAvailable: true,
    runtimeError: false, runtimeReads: 0, destroyed: 0
  };
  const context = { filesDir: '/tools-fixture' };
  const schedule = (run, delay, repeat) => {
    const id = ++nextTimer;
    timers.set(id, { run, delay, repeat, at: now + delay });
    return id;
  };
  const clock = {
    Date: class extends Date {
      constructor(...args) { super(...(args.length === 0 ? [now] : args)); }
      static now() { return now; }
    },
    setTimeout: (run, delay) => schedule(run, delay, false),
    clearTimeout: id => timers.delete(id),
    setInterval: (run, delay) => schedule(run, delay, true),
    clearInterval: id => timers.delete(id)
  };
  const pref = {
    async get(key, fallback) {
      const result = controls.preferences.has(key) ? controls.preferences.get(key) : fallback;
      controls.preferenceCalls.push(['get', key]);
      await controls.preferenceGetGate;
      if (controls.preferenceGetError) throw new Error('private preference failure');
      return result;
    },
    getSync(key, fallback) { return controls.preferences.has(key) ? controls.preferences.get(key) : fallback; },
    async put(key, value) {
      controls.preferenceCalls.push(['put', key, value]);
      controls.preferences.set(key, value);
    },
    async delete(key) { controls.preferences.delete(key); },
    async flush() {
      controls.preferenceCalls.push(['flush']);
      await controls.preferenceFlushGate;
      await controls.beforePreferenceFlush?.();
      if (controls.preferenceFlushError || controls.preferenceFlushFailures > 0) {
        controls.preferenceFlushFailures = Math.max(0, controls.preferenceFlushFailures - 1);
        throw new Error('private flush failure');
      }
    }
  };
  const runtime = {
    CONTROLLER_ADDRESS: '127.0.0.1:19090',
    async readRuntime() {
      ++controls.runtimeReads;
      await controls.runtimeGate;
      if (controls.runtimeError) throw new Error('private runtime failure');
      return controls.runtimeAvailable ? { secret: 'fixture-secret' } : undefined;
    }
  };
  const network = {
    http: {
      RequestMethod: { GET: 'GET', POST: 'POST', PATCH: 'PATCH', DELETE: 'DELETE' },
      HttpDataType: { STRING: 0 },
      createHttp() {
        return {
          async request(address, options) {
            assert.equal(options.header.Authorization, 'Bearer fixture-secret');
            const body = options.extraData === undefined ? undefined : JSON.parse(options.extraData);
            requests.push({ address, route: new URL(address).pathname, method: options.method, body, options });
            const status = controls.actionStatus;
            const message = controls.actionMessage;
            const failure = controls.actionError;
            await controls.actionGate;
            if (failure) throw new Error('private transport failure fixture.example');
            return { responseCode: status, result: status === 204 ? '' : JSON.stringify({ message }) };
          },
          destroy() { ++controls.destroyed; }
        };
      }
    },
    webSocket: {
      createWebSocket() {
        const callbacks = new Map();
        const socket = {
          callbacks, closed: false, address: '',
          on(name, callback) { callbacks.set(name, callback); },
          off(name) { callbacks.delete(name); },
          async connect(address, options) {
            assert.equal(options.header.Authorization, 'Bearer fixture-secret');
            socket.address = address;
            if (controls.connectError) throw new Error('private websocket failure');
            return controls.connectCreated;
          },
          async close() { socket.closed = true; },
          capture(name) { return callbacks.get(name); },
          emit(frame) { callbacks.get('message')?.(undefined, typeof frame === 'string' ? frame : JSON.stringify(frame)); },
          open() { callbacks.get('open')?.(undefined); },
          disconnect() { callbacks.get('close')?.(); },
          error() { callbacks.get('error')?.(new Error('private websocket failure')); }
        };
        sockets.push(socket);
        return socket;
      }
    }
  };
  const kits = {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.NetworkKit': network,
    '@kit.ArkData': { preferences: { async getPreferences() {
      if (controls.preferenceGetError) throw new Error('private preferences unavailable');
      return pref;
    } } }
  };
  function load(relative) {
    const absolute = path.resolve(etsDir, relative);
    if (modules.has(absolute)) return modules.get(absolute).exports;
    const source = fs.readFileSync(absolute, 'utf8')
      .replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
    const compiled = ts.transpileModule(source, {
      fileName: absolute.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
    }).outputText;
    const module = { exports: {} };
    modules.set(absolute, module);
    const bindings = {
      module, exports: module.exports, console, ...clock,
      DataOperationType: { ADD: 'add', DELETE: 'delete', CHANGE: 'change', EXCHANGE: 'exchange' },
      require(name) {
        if (name in kits) return kits[name];
        assert.ok(name.startsWith('.'), `unexpected platform dependency ${name}`);
        const target = path.resolve(path.dirname(absolute), `${name}.ets`);
        if (target === path.join(etsDir, 'shared/Runtime.ets')) return runtime;
        return load(path.relative(etsDir, target));
      }
    };
    vm.compileFunction(compiled, Object.keys(bindings), { filename: absolute })(...Object.values(bindings));
    if (module.exports.connectionRecords) tracked.add(module.exports.connectionRecords);
    if (module.exports.dnsRecords) tracked.add(module.exports.dnsRecords);
    return module.exports;
  }
  async function flush() {
    for (let round = 0; round < 80; round++) await Promise.resolve();
  }
  async function advance(milliseconds) {
    const end = now + milliseconds;
    for (;;) {
      const due = [...timers].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at || a[0] - b[0]);
      if (due.length === 0) break;
      const [id, timer] = due[0];
      now = timer.at;
      if (timer.repeat) timer.at += timer.delay;
      else timers.delete(id);
      timer.run();
      await flush();
    }
    now = end;
    await flush();
  }
  function track(value) { tracked.add(value); return value; }
  async function cleanup() {
    for (const value of tracked) {
      if (value.setVisible) value.setVisible(false);
      else value.stop();
    }
    await flush();
    assert.equal(timers.size, 0, 'every case must release product timers');
    assert.ok(sockets.every(socket => socket.closed), 'every case must close platform sockets');
  }
  return { load, controls, context, advance, flush, sockets, requests, timers, cleanup, track,
    get now() { return now; } };
}

function deferredTools() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

async function toolsCase(run) {
  const h = createToolsHarness();
  try { await run(h); }
  finally { await h.cleanup(); }
}

export function toolConnection(id, options = {}) {
  return { id, start: '2026-01-01T00:00:00.000000001Z',
  chains: ['Exit', 'Main'], providerChains: [], rule: 'Domain', rulePayload: 'example',
  upload: 0, download: 0, ...options, metadata: {
    network: 'tcp', type: 'HTTP', sourceIP: '127.0.0.1', sourcePort: '42000',
    destinationIP: '2001:db8::1', destinationPort: '443', host: 'fixture.example', dnsMode: 'normal',
    remoteDestination: '', sourceIPASN: '', destinationIPASN: 'AS64500', specialProxy: '', specialRules: '',
    sniffHost: '', sourceGeoIP: [], destinationGeoIP: ['ZZ'], ...options.metadata
  } };
}

export function toolDns(id, options = {}) {
  return { id, domain: 'fixture.example', type: 'A', initiator: 'app', upstream: '', rcode: 'NOERROR',
    error: '', cached: false, answers: ['127.0.0.1'], delay: 3, time: '2026-01-01T00:00:00.000000001Z', ...options };
}

export function toolFrame(type = 'connections', kind = 'snapshot', seq = 1, options = {}) {
  return { type, kind, bootId: 'boot-a', configRevision: 1, sessionId: 'session-a', seq,
    sampledAt: Date.parse('2026-01-01T00:00:01Z') + seq * 1000, dropped: 0, evicted: 0,
    ...(type === 'connections' ? kind === 'delta' ? { opened: [], traffic: [], closed: [] } : { live: [], recent: [] } :
      kind === 'delta' ? { added: [] } : { records: [] }), ...options };
}

async function onlineTools(h, type = 'connections', options = {}) {
  const { ConnectionRecordsStore, DnsRecordsStore } = h.load('features/tools/RecordStores.ets');
  const store = h.track(type === 'connections' ? new ConnectionRecordsStore() : new DnsRecordsStore());
  store.setConnection(true, options.bootId ?? 'boot-a', options.configRevision ?? 1);
  store.setVisible(true);
  await store.load(h.context);
  await h.flush();
  const socket = h.sockets.at(-1);
  assert.ok(socket);
  assert.equal(store.canAct, false, 'connect request is not a handshake or baseline');
  socket.open();
  assert.equal(store.canAct, false, 'handshake is not a baseline');
  socket.emit(toolFrame(type, 'snapshot', 1, options));
  assert.equal(store.canAct, true);
  return { store, socket };
}

const connectionIds = store => Array.from(store.source.values()).filter(row => row.record).map(row => row.record.connection.id);
const dnsIds = store => Array.from(store.source.values(), row => row.record.id);

test('baseline只进live；同tick短请求保留recent，关闭后累计值仍可收尾且一帧只刷新一次', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'connections', { live: [toolConnection('baseline')] });
  assert.deepEqual(connectionIds(store), ['baseline']);
  store.setFeed('recent');
  await h.flush();
  assert.equal(store.totalRecords, 0);
  const before = store.version;
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('short')],
    traffic: [{ id: 'short', upload: 12, download: 34 }], closed: ['short'] }));
  assert.equal(store.version, before + 1);
  assert.deepEqual(connectionIds(store), ['short']);
  assert.equal(store.source.getData(0).record.connection.download, 34);
  const unchanged = store.source.getData(0);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('duplicate')] }));
  assert.strictEqual(store.source.getData(0), unchanged);
  assert.equal(store.version, before + 1);
  socket.emit(toolFrame('connections', 'delta', 3, { traffic: [{ id: 'short', upload: 14, download: 40 }] }));
  assert.equal(store.source.getData(0).record.connection.download, 40);
  store.setFeed('live');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['baseline']);
  assert.equal(h.sockets.length, 1);
}));

test('活跃连接的流量原地更新；一帧内关闭、新增和换位不会重建存活行', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'connections', {
    live: ['a', 'b', 'c', 'd'].map(id => toolConnection(id))
  });
  const [a, b, c] = store.source.values();
  const batches = [];
  store.source.registerDataChangeListener({
    onDatasetChange(operations) { batches.push(plain(operations)); }
  });
  socket.emit(toolFrame('connections', 'delta', 2, { traffic: [{ id: 'a', upload: 0, download: 20 }] }));
  assert.strictEqual(store.source.getData(0), a);
  assert.equal(a.record.downloadSpeed, 20);
  assert.deepEqual(batches, []);

  socket.emit(toolFrame('connections', 'delta', 3, {
    opened: [toolConnection('e')], closed: ['d'],
    traffic: [{ id: 'b', upload: 0, download: 1000 }, { id: 'c', upload: 0, download: 500 }]
  }));
  assert.deepEqual(connectionIds(store), ['b', 'c', 'a', 'e']);
  assert.strictEqual(store.source.getData(0), b);
  assert.strictEqual(store.source.getData(1), c);
  assert.strictEqual(store.source.getData(2), a);
  assert.equal(b.record.downloadSpeed, 1000);
  assert.ok(batches.length > 0, 'native list must receive the new structure');
  for (const operation of batches.flat()) {
    assert.ok(['add', 'delete', 'move', 'exchange'].includes(operation.type), 'no full reload or row rebuild');
  }
}));

test('seq缺口停止流且保持真实历史；非法帧不重试，手动retry取得新baseline', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('seen')] }));
  socket.emit(toolFrame('connections', 'delta', 4, { opened: [toolConnection('gap')] }));
  assert.equal(store.error, 'diagnostics_invalid_data');
  assert.equal(store.streamState, 'failed');
  assert.equal(store.canAct, false);
  assert.equal(store.totalRecords, 0);
  assert.equal(socket.closed, true);
  assert.equal(h.timers.size, 0);
  store.setFeed('recent');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['seen']);
  store.retry();
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-b', live: [toolConnection('baseline-b')] }));
  assert.equal(store.canAct, true);
  assert.deepEqual(connectionIds(store), ['seen']);
  h.sockets.at(-1).emit('{broken');
  assert.equal(store.error, 'diagnostics_invalid_data');
  assert.equal(h.timers.size, 0);
}));

test('断流立即撤销live和动作；重连保留历史但不补baseline，隐藏取消timer且旧回调无效', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('seen')] }));
  const staleMessage = socket.capture('message');
  const staleOpen = socket.capture('open');
  socket.disconnect();
  assert.equal(store.streamState, 'retrying');
  assert.equal(store.totalRecords, 0);
  assert.equal(store.canAct, false);
  assert.equal(store.interruptions, 1);
  await store.closeAll();
  assert.equal(h.requests.length, 0);
  await h.advance(2000);
  const current = h.sockets.at(-1);
  assert.notStrictEqual(current, socket);
  current.open();
  current.emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-b', live: [toolConnection('hidden')] }));
  staleOpen(undefined);
  staleMessage(undefined, JSON.stringify(toolFrame('connections', 'delta', 3, { opened: [toolConnection('stale')] })));
  store.setFeed('recent');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['seen']);
  store.select('seen');
  store.setQuery('fixture');
  store.toggleFacet('network', 'tcp');
  store.setGrouping('host');
  store.setFeed('live');
  await h.flush();
  assert.equal(h.sockets.length, 2, 'feed, filters and detail never restart collection');
  assert.deepEqual(connectionIds(store), ['hidden']);
  current.disconnect();
  assert.equal(h.timers.size, 1);
  store.setVisible(false);
  assert.equal(h.timers.size, 0);
  await h.advance(20000);
  assert.equal(h.sockets.length, 2);
  store.setVisible(true);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-c' }));
  store.setFeed('recent');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['seen']);
}));

test('configRevision零断开保留历史；相同身份不重连，新boot或配置清空详情和历史', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('seen')] }));
  store.select('seen');
  store.setConnection(true, 'boot-a', 1);
  assert.equal(h.sockets.length, 1);
  store.setConnection(false, '', 0);
  store.setFeed('recent');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['seen']);
  assert.ok(store.selected);
  store.setConnection(true, 'boot-a', 1);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-b' }));
  assert.deepEqual(connectionIds(store), ['seen']);
  store.setConnection(true, 'boot-a', 2);
  assert.equal(store.totalRecords, 0);
  assert.equal(store.selectedId, '');
  assert.equal(store.selected, undefined);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { configRevision: 2, sessionId: 'session-c' }));
  h.sockets.at(-1).emit(toolFrame('connections', 'delta', 2, { configRevision: 2, sessionId: 'session-c', opened: [toolConnection('new')] }));
  assert.equal(store.totalRecords, 1);
  store.setConnection(true, 'boot-b', 2);
  assert.equal(store.totalRecords, 0);
}));

test('reset替换当前分区而保留旧会话与暂停头；恢复following才回收暂停额外记录', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('old-session')], closed: ['old-session'] }));
  store.setVisible(false);
  store.setVisible(true);
  await h.flush();
  const current = h.sockets.at(-1);
  current.open();
  current.emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-b' }));
  current.emit(toolFrame('connections', 'delta', 2, { sessionId: 'session-b', opened: [toolConnection('head'), toolConnection('remove')], closed: ['head', 'remove'] }));
  store.setFeed('recent');
  await h.flush();
  store.setFollowing(false);
  store.setAnchor('head');
  current.emit(toolFrame('connections', 'reset', 3, { sessionId: 'session-b', recent: [toolConnection('tail')], dropped: 257, evicted: 4 }));
  assert.deepEqual(connectionIds(store), ['tail', 'remove', 'head', 'old-session']);
  assert.equal(store.anchorKey, 'head');
  assert.equal(store.dropped, 257);
  assert.equal(store.evicted, 4);
  store.setFollowing(true);
  assert.deepEqual(connectionIds(store), ['tail', 'old-session']);
  assert.equal(store.anchorKey, '');
  current.emit(toolFrame('connections', 'reset', 4, { sessionId: 'session-b', recent: [], live: [toolConnection('active')], dropped: 258 }));
  assert.deepEqual(connectionIds(store), ['old-session']);
  store.setFeed('live');
  await h.flush();
  assert.deepEqual(connectionIds(store), ['active']);
}));

test('连接2000/暂停4000上限不截断live，锚被淘汰时迁移到保留行，resume只保留canonical', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  const first = Array.from({ length: 2001 }, (_, index) => toolConnection(`r${index}`));
  socket.emit(toolFrame('connections', 'delta', 2, { opened: first }));
  assert.equal(store.totalRecords, 2001);
  store.setFeed('recent');
  await h.flush();
  assert.equal(store.totalRecords, 2000);
  assert.equal(connectionIds(store).at(-1), 'r1');
  store.setFollowing(false);
  store.setAnchor('r1');
  const second = Array.from({ length: 2001 }, (_, index) => toolConnection(`n${index}`));
  socket.emit(toolFrame('connections', 'delta', 3, { opened: second }));
  assert.equal(store.totalRecords, 4000);
  assert.equal(store.anchorKey, 'r2');
  assert.equal(connectionIds(store)[0], 'n2000');
  store.setFollowing(true);
  assert.equal(store.totalRecords, 2000);
  assert.equal(connectionIds(store).at(-1), 'n1');
  store.setFeed('live');
  await h.flush();
  assert.equal(store.totalRecords, 4002);
}));

test('同一内容保留行对象，查询筛选分组跨feed共享，各feed排序独立且无新订阅', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h);
  socket.emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('a'), toolConnection('b', { metadata: { network: 'udp', host: 'other.example' } })] }));
  store.setFeed('recent');
  await h.flush();
  const old = store.source.values().find(row => row.key === 'a');
  socket.emit(toolFrame('connections', 'delta', 3));
  assert.strictEqual(store.source.values().find(row => row.key === 'a'), old);
  store.setQuery('FIXTURE 443');
  store.toggleFacet('network', 'tcp');
  store.setGrouping('host');
  store.setSort({ column: 'target', direction: 'asc' });
  assert.equal(store.visibleRecords, 1);
  assert.equal(store.source.totalCount(), 2);
  const header = store.source.getData(0);
  store.toggleGroup(header.key.slice('group:'.length));
  assert.equal(store.source.totalCount(), 1);
  store.toggleGroup(header.key.slice('group:'.length));
  store.setFeed('live');
  await h.flush();
  assert.equal(store.sort.column, '');
  assert.equal(store.query, 'FIXTURE 443');
  assert.equal(store.grouping, 'host');
  assert.equal(store.visibleRecords, 1);
  store.setSort({ column: 'downloadSpeed', direction: 'desc' });
  store.setFeed('recent');
  await h.flush();
  assert.equal(store.sort.column, 'target');
  assert.equal(h.sockets.length, 1);
}));

test('close动作使用真实204和身份，不乐观删除，重复pending拒绝，迟到或stale响应无Toast', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'connections', { live: [toolConnection('active')] });
  const gate = deferredTools();
  h.controls.actionGate = gate.promise;
  const closing = store.closeOne('active');
  await h.flush();
  assert.equal(store.actionPending, true);
  await store.closeAll();
  assert.equal(h.requests.length, 1);
  assert.deepEqual(h.requests[0].body, { expectedBootId: 'boot-a', expectedConfigRevision: 1, scope: 'one', id: 'active' });
  assert.deepEqual(connectionIds(store), ['active']);
  gate.resolve();
  await closing;
  assert.equal(store.notice, 'closed');
  assert.deepEqual(connectionIds(store), ['active']);
  socket.emit(toolFrame('connections', 'delta', 2, { closed: ['active'] }));
  assert.equal(store.totalRecords, 0);
  h.controls.actionGate = undefined;
  store.clearNotice();
  await store.closeAll();
  assert.deepEqual(h.requests.at(-1).body, { expectedBootId: 'boot-a', expectedConfigRevision: 1, scope: 'all' });
  assert.equal(h.controls.destroyed, 2);
  store.clearNotice();
  const late = deferredTools();
  h.controls.actionGate = late.promise;
  const pending = store.closeAll();
  await h.flush();
  store.setVisible(false);
  late.resolve();
  await pending;
  assert.equal(store.notice, '');
  store.setVisible(true);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { sessionId: 'session-b' }));
  h.controls.actionGate = undefined;
  h.controls.actionStatus = 409;
  h.controls.actionMessage = 'diagnostics_stale_runtime';
  await store.closeAll();
  assert.equal(store.notice, '');
  h.controls.actionMessage = 'private node fixture.example';
  await store.closeAll();
  assert.equal(store.notice, 'error');
  assert.equal(store.noticeError, 'diagnostics_operation_failed');
}));

test('DNS流独立、错误/无upstream保真，重复seq无重复，清缓存成功和失败均不清记录', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'dns');
  assert.ok(socket.address.includes('/diagnostics/dns?'));
  assert.equal(h.sockets.length, 1);
  const record = toolDns('dns-one', { rcode: 'NXDOMAIN', answers: [], upstream: '', initiator: 'rule' });
  socket.emit(toolFrame('dns', 'delta', 2, { added: [record] }));
  const row = store.source.getData(0);
  socket.emit(toolFrame('dns', 'delta', 2, { added: [record] }));
  assert.strictEqual(store.source.getData(0), row);
  socket.emit(toolFrame('dns', 'reset', 3, { records: [record], dropped: 300, evicted: 12 }));
  assert.strictEqual(store.source.getData(0), row);
  store.select('dns-one');
  assert.equal(store.selected.upstream, '');
  assert.equal(store.selected.rcode, 'NXDOMAIN');
  await store.clearCache();
  assert.equal(store.notice, 'cacheCleared');
  assert.deepEqual(dnsIds(store), ['dns-one']);
  assert.deepEqual(h.requests[0].body, { expectedBootId: 'boot-a', expectedConfigRevision: 1 });
  assert.equal(h.requests[0].route, '/arkclash/diagnostics/dns/clear-cache');
  store.clearNotice();
  h.controls.actionStatus = 503;
  h.controls.actionMessage = 'private resolver fixture.example';
  await store.clearCache();
  assert.equal(store.noticeError, 'diagnostics_operation_failed');
  assert.deepEqual(dnsIds(store), ['dns-one']);
  store.setQuery('nxdomain rule');
  store.toggleFacet('cache', 'false');
  assert.equal(store.visibleRecords, 1);
}));

test('DNS3000/暂停6000边界、reset保留暂停头和旧会话，新配置清空', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'dns');
  socket.emit(toolFrame('dns', 'delta', 2, { added: Array.from({ length: 3001 }, (_, i) => toolDns(`d${i}`)) }));
  assert.equal(store.totalRecords, 3000);
  assert.equal(dnsIds(store).at(-1), 'd1');
  store.setFollowing(false);
  store.setAnchor('d1');
  socket.emit(toolFrame('dns', 'delta', 3, { added: Array.from({ length: 3001 }, (_, i) => toolDns(`n${i}`)) }));
  assert.equal(store.totalRecords, 6000);
  assert.equal(store.anchorKey, 'd2');
  socket.emit(toolFrame('dns', 'reset', 4, { records: [toolDns('retained')], dropped: 500, evicted: 400 }));
  assert.equal(store.totalRecords, 6000);
  assert.ok(dnsIds(store).includes('d3'));
  store.setFollowing(true);
  assert.deepEqual(dnsIds(store), ['retained']);
  store.setVisible(false);
  store.setConnection(false, '', 0);
  assert.deepEqual(dnsIds(store), ['retained']);
  store.setConnection(true, 'boot-a', 1);
  store.setVisible(true);
  await h.flush();
  const next = h.sockets.at(-1);
  next.open();
  next.emit(toolFrame('dns', 'snapshot', 1, { sessionId: 'session-b' }));
  next.emit(toolFrame('dns', 'delta', 2, { sessionId: 'session-b', added: [toolDns('current')] }));
  next.emit(toolFrame('dns', 'reset', 3, { sessionId: 'session-b', records: [] }));
  assert.deepEqual(dnsIds(store), ['retained']);
  store.select('retained');
  store.setConnection(true, 'boot-a', 2);
  assert.equal(store.totalRecords, 0);
  assert.equal(store.selectedId, '');
}));

test('DNS断流拒绝动作和seq缺口，隐藏或新代次的旧HTTP响应不能回放通知', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'dns');
  socket.emit(toolFrame('dns', 'delta', 2, { added: [toolDns('seen')] }));
  const gate = deferredTools();
  h.controls.actionGate = gate.promise;
  const pending = store.clearCache();
  await h.flush();
  await store.clearCache();
  assert.equal(h.requests.length, 1);
  store.setConnection(true, 'boot-b', 1);
  gate.resolve();
  await pending;
  assert.equal(store.notice, '');
  await h.flush();
  const current = h.sockets.at(-1);
  current.open();
  current.emit(toolFrame('dns', 'snapshot', 1, { bootId: 'boot-b', sessionId: 'session-b' }));
  current.disconnect();
  assert.equal(store.canAct, false);
  assert.equal(store.actionPending, false);
  await store.clearCache();
  assert.equal(h.requests.length, 1);
  await h.advance(2000);
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('dns', 'snapshot', 1, { bootId: 'boot-b', sessionId: 'session-c' }));
  h.sockets.at(-1).emit(toolFrame('dns', 'delta', 3, { bootId: 'boot-b', sessionId: 'session-c', added: [toolDns('gap')] }));
  assert.equal(store.error, 'diagnostics_invalid_data');
  assert.equal(store.totalRecords, 0);
  assert.equal(h.timers.size, 0);
}));

test('偏好迟到load不覆盖修改或阻塞采集，保存失败回滚且可显式重试', async () => toolsCase(async h => {
  const gate = deferredTools();
  h.controls.preferenceGetGate = gate.promise;
  h.controls.preferences.set('diagnostics.requestFeed', 'live');
  const { ConnectionRecordsStore } = h.load('features/tools/RecordStores.ets');
  const store = h.track(new ConnectionRecordsStore());
  store.setConnection(true, 'boot-a', 1);
  store.setVisible(true);
  const loading = store.load(h.context);
  await h.flush();
  assert.equal(h.sockets.length, 1);
  h.sockets[0].open();
  h.sockets[0].emit(toolFrame());
  store.setFeed('recent');
  store.setGrouping('rule');
  const saving = store.saveColumnWidths({ target: 180 });
  await h.flush();
  h.sockets[0].emit(toolFrame('connections', 'delta', 2, { opened: [toolConnection('while-loading')], closed: ['while-loading'] }));
  assert.equal(store.totalRecords, 1);
  gate.resolve();
  await Promise.all([loading, saving]);
  await h.flush();
  assert.equal(store.feed, 'recent');
  assert.equal(store.grouping, 'rule');
  assert.equal(store.columnWidths.target, 180);
  h.controls.preferenceFlushFailures = 1;
  store.setGrouping('host');
  await h.flush();
  assert.equal(store.grouping, 'rule');
  assert.equal(store.preferenceError, 'diagnostics_preferences_failed');
  await store.retryPreferences();
  assert.equal(store.grouping, 'host');
  assert.equal(store.preferenceError, '');
  assert.equal(h.sockets.length, 1);
}));

test('DNS偏好失败不阻塞流；列宽保存失败回滚和retry，迟到load不覆盖新宽度', async () => toolsCase(async h => {
  h.controls.preferenceGetError = true;
  const { store, socket } = await onlineTools(h, 'dns');
  assert.equal(store.preferenceError, 'diagnostics_preferences_failed');
  socket.emit(toolFrame('dns', 'delta', 2, { added: [toolDns('captured')] }));
  assert.equal(store.totalRecords, 1);
  h.controls.preferenceGetError = false;
  await store.retryPreferences();
  assert.equal(store.preferenceError, '');
  await store.saveColumnWidths({ domain: 210 });
  h.controls.preferenceFlushFailures = 1;
  await assert.rejects(store.saveColumnWidths({ domain: 320 }), /diagnostics_preferences_failed/);
  assert.equal(store.columnWidths.domain, 210);
  assert.equal(store.preferenceError, 'diagnostics_preferences_failed');
  await store.retryPreferences();
  assert.equal(store.columnWidths.domain, 320);
  const gate = deferredTools();
  h.controls.preferenceGetGate = gate.promise;
  const loading = store.load(h.context);
  await h.flush();
  const saving = store.saveColumnWidths({ domain: 410 });
  gate.resolve();
  await Promise.all([loading, saving]);
  assert.equal(store.columnWidths.domain, 410);
  assert.equal(store.totalRecords, 1);
}));

test('ControllerSocket握手状态、旧代次回调、五次有界重试与无第三参兼容', async () => toolsCase(async h => {
  const { ControllerSocket } = h.load('client/ControllerSocket.ets');
  const states = [];
  const messages = [];
  const stream = h.track(new ControllerSocket('/fixture', text => messages.push(text), state => states.push(state)));
  stream.start(h.context.filesDir);
  await h.flush();
  const first = h.sockets[0];
  assert.equal(stream.state, 'connecting');
  const oldOpen = first.capture('open');
  const oldClose = first.capture('close');
  const oldMessage = first.capture('message');
  first.open();
  assert.equal(stream.state, 'open');
  first.disconnect();
  assert.equal(stream.state, 'retrying');
  oldOpen(undefined);
  oldMessage(undefined, 'old');
  oldClose();
  assert.deepEqual(messages, []);
  assert.equal(h.timers.size, 1);
  for (let retry = 0; retry < 5; retry++) {
    await h.advance(2000);
    h.sockets.at(-1).open();
    h.sockets.at(-1).disconnect();
  }
  assert.equal(h.sockets.length, 6);
  assert.equal(stream.state, 'failed');
  assert.equal(h.timers.size, 0);
  assert.ok(states.includes('connecting') && states.includes('open') && states.includes('retrying') && states.includes('failed'));
  stream.start(h.context.filesDir);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit('new');
  assert.deepEqual(messages, ['new']);
  stream.stop();
  assert.equal(stream.state, 'closed');
  const legacy = h.track(new ControllerSocket('/legacy', text => messages.push(text)));
  legacy.start(h.context.filesDir);
  await h.flush();
  h.sockets.at(-1).emit('legacy');
  assert.deepEqual(messages, ['new', 'legacy']);
  legacy.stop();
}));

test('ControllerSocket隐藏取消pending runtime和connect失败重连，消息重置重试预算', async () => toolsCase(async h => {
  const { ControllerSocket } = h.load('client/ControllerSocket.ets');
  const gate = deferredTools();
  h.controls.runtimeGate = gate.promise;
  const states = [];
  const stream = h.track(new ControllerSocket('/fixture', () => {}, state => states.push(state)));
  stream.start(h.context.filesDir);
  stream.stop();
  gate.resolve();
  await h.flush();
  assert.equal(h.sockets.length, 0);
  assert.equal(stream.state, 'closed');
  h.controls.runtimeGate = undefined;
  h.controls.connectError = true;
  stream.start(h.context.filesDir);
  await h.flush();
  assert.equal(stream.state, 'retrying');
  assert.equal(h.timers.size, 1);
  h.controls.connectError = false;
  await h.advance(2000);
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit('valid-data');
  h.sockets.at(-1).disconnect();
  for (let retry = 0; retry < 5; retry++) {
    await h.advance(2000);
    h.sockets.at(-1).disconnect();
  }
  assert.equal(stream.state, 'failed');
  assert.equal(h.sockets.length, 7);
  stream.stop();
  h.controls.runtimeAvailable = false;
  stream.start(h.context.filesDir);
  await h.flush();
  assert.equal(stream.state, 'closed');
  assert.equal(h.timers.size, 0);
}));

test('真实parser逐字段验证数组/身份/时间/计数/initiator，坏协议停止且不输出原始错误', async () => toolsCase(async h => {
  const client = h.load('client/Diagnostics.ets');
  const runtime = { bootId: 'boot-a', configRevision: 1 };
  const valid = toolFrame('connections', 'delta', 2, { opened: [toolConnection('one')], traffic: [{ id: 'one', upload: 1, download: 2 }], closed: ['one'] });
  const parsed = client.parseDiagnosticConnections(JSON.stringify(valid), runtime);
  assert.equal(parsed.live.length, 0);
  assert.equal(parsed.opened[0].metadata.destinationIP, '2001:db8::1');
  for (const change of [
    frame => { frame.type = 'dns'; }, frame => { frame.kind = 'bogus'; },
    frame => { frame.bootId = 'old'; }, frame => { frame.configRevision = 0; },
    frame => { frame.seq = 0; }, frame => { frame.seq = 1.5; }, frame => { frame.seq = Number.MAX_SAFE_INTEGER + 1; },
    frame => { frame.sampledAt = -1; }, frame => { frame.dropped = -1; }, frame => { frame.evicted = 0.5; },
    frame => { frame.sessionId = ''; }, frame => { frame.opened = null; },
    frame => { frame.traffic[0].upload = -1; }, frame => { frame.closed = [1]; },
    frame => { frame.opened[0].metadata.sourceGeoIP = [1]; },
    frame => { frame.opened[0].start = 'not-a-date'; },
    frame => { frame.opened[0].chains = null; }, frame => { frame.opened[0].metadata.destinationPort = 443; }
  ]) {
    const frame = plain(valid); change(frame);
    assert.throws(() => client.parseDiagnosticConnections(JSON.stringify(frame), runtime), /diagnostics_invalid_data/);
  }
  for (const text of ['null', '[]', '42', '"raw"', '{invalid']) {
    assert.throws(() => client.parseDiagnosticConnections(text, runtime), /diagnostics_invalid_data/);
  }
  const dns = toolFrame('dns', 'delta', 2, { added: [toolDns('one')] });
  for (const change of [frame => { frame.added = null; }, frame => { frame.added[0].answers = [1]; },
    frame => { frame.added[0].initiator = 'fake-app'; }, frame => { frame.added[0].delay = -1; },
    frame => { frame.added[0].cached = 'false'; }, frame => { frame.added[0].time = ''; }]) {
    const frame = plain(dns); change(frame);
    assert.throws(() => client.parseDiagnosticDns(JSON.stringify(frame), runtime), /diagnostics_invalid_data/);
  }
  const stream = h.track(client.createDnsStream(runtime, () => assert.fail('invalid frame delivered'), () => {}));
  stream.start(h.context.filesDir);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit('{private malformed payload');
  assert.equal(stream.state, 'failed');
  assert.equal(stream.failure, 'diagnostics_invalid_data');
  assert.equal(h.timers.size, 0);
}));

test('客户端动作校验one/all身份并只走专用HTTP接口，错误规范化且destroy总执行', async () => toolsCase(async h => {
  const client = h.load('client/Diagnostics.ets');
  const runtime = { bootId: 'boot & a', configRevision: 7 };
  const stream = h.track(client.createConnectionsStream(runtime, () => {}, () => {}));
  stream.start(h.context.filesDir);
  await h.flush();
  const address = new URL(h.sockets.at(-1).address);
  assert.equal(address.searchParams.get('expectedBootId'), runtime.bootId);
  assert.equal(address.searchParams.get('expectedConfigRevision'), '7');
  await client.closeDiagnosticConnections(h.context.filesDir, runtime, 'one', 'id');
  await client.closeDiagnosticConnections(h.context.filesDir, runtime, 'all');
  await client.clearDiagnosticDnsCache(h.context.filesDir, runtime);
  assert.deepEqual(h.requests.map(request => request.body), [
    { expectedBootId: runtime.bootId, expectedConfigRevision: 7, scope: 'one', id: 'id' },
    { expectedBootId: runtime.bootId, expectedConfigRevision: 7, scope: 'all' },
    { expectedBootId: runtime.bootId, expectedConfigRevision: 7 }
  ]);
  await assert.rejects(client.closeDiagnosticConnections(h.context.filesDir, runtime, 'one'), /diagnostics_invalid_request/);
  await assert.rejects(client.closeDiagnosticConnections(h.context.filesDir, runtime, 'one', ''), /diagnostics_invalid_request/);
  await assert.rejects(client.closeDiagnosticConnections(h.context.filesDir, runtime, 'all', 'id'), /diagnostics_invalid_request/);
  await assert.rejects(client.clearDiagnosticDnsCache(h.context.filesDir, { bootId: '', configRevision: 0 }), /diagnostics_invalid_request/);
  assert.equal(h.requests.length, 3);
  h.controls.actionStatus = 409;
  h.controls.actionMessage = 'diagnostics_stale_runtime';
  await assert.rejects(client.clearDiagnosticDnsCache(h.context.filesDir, runtime), /diagnostics_stale_runtime/);
  h.controls.actionError = true;
  await assert.rejects(client.clearDiagnosticDnsCache(h.context.filesDir, runtime), /diagnostics_operation_failed/);
  assert.equal(h.controls.destroyed, 5);
}));

function connection(id, patch = {}) {
  return {
    id, start: '1970-01-01T00:00:00.000Z', upload: 0, download: 0,
    chains: [], providerChains: [], rule: 'MATCH', rulePayload: '',
    ...patch,
    metadata: {
      network: 'tcp', type: 'HTTP', sourceIP: '192.0.2.2', sourcePort: '1234',
      destinationIP: '2001:db8::1', destinationPort: '443', host: 'Example.COM', dnsMode: 'normal',
      remoteDestination: '', sourceIPASN: '', destinationIPASN: '', specialProxy: '', specialRules: '',
      sniffHost: '', sourceGeoIP: [], destinationGeoIP: [], ...(patch.metadata ?? {})
    }
  };
}

function row(id, patch = {}, speeds = {}) {
  return { key: id, connection: connection(id, patch), uploadSpeed: 0, downloadSpeed: 0,
    rankSpeed: 0, duration: 0, ...speeds };
}

function dns(id, patch = {}) {
  return { id, domain: 'Example.COM', type: 'A', initiator: 'app', upstream: '', rcode: 'NOERROR',
    error: '', cached: false, answers: ['192.0.2.4'], delay: 10,
    time: '2026-01-01T00:00:00Z', ...patch };
}

const ids = records => records.map(record => record.key ?? record.id);
const closeTo = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8, `${actual} != ${expected}`);

function registerToolsLogicTests(createHarness) {
  const run = (name, body) => test(name, async () => {
    const h = createHarness();
    try {
      await body(h, h.load('features/tools/RecordLogic.ets'));
    } finally {
      await h.cleanup();
    }
  });

  run('record search matches all casefolded words across every diagnostic field', (h, l) => {
    const rich = row('rich', { chains: ['exit-a', 'middle'], providerChains: ['provider-b'],
      rule: 'DOMAIN', rulePayload: 'example', metadata: {
        sourceGeoIP: ['US'], destinationGeoIP: ['DE'], sourceIPASN: 'AS123', destinationIPASN: 'AS456',
        remoteDestination: 'remote.test', specialProxy: 'special-exit', specialRules: 'special-rule',
        sniffHost: 'sniff.test'
      } });
    const other = row('other', { metadata: { host: 'other.test', network: 'udp' } });
    const records = [rich, other];
    assert.deepEqual(ids(l.filterConnections(records, '  EXAMPLE   TCP AS123 de exit-a PROVIDER-B ', {})), ['rich']);
    for (const term of ['HTTP', '192.0.2.2', '1234', '2001:db8::1', '443', 'US', 'AS456',
      'remote.test', 'special-exit', 'special-rule', 'sniff.test', 'normal']) {
      assert.ok(l.filterConnections([rich], term, {}).length === 1, term);
    }
    assert.deepEqual(l.filterConnections(records, 'example udp', {}), []);
    assert.equal(l.filterConnections(records, '', {})[0], rich);
    assert.deepEqual(ids(records), ['rich', 'other']);
  });

  run('record facets OR within one field and AND across fields without losing rare selections', (h, l) => {
    const a = row('a', { chains: ['exit', 'middle'], rule: 'DOMAIN', rulePayload: 'x' });
    const b = row('b', { metadata: { network: 'udp' }, chains: ['other'] });
    const c = row('c', { chains: ['third'] });
    assert.deepEqual(ids(l.filterConnections([a, b, c], '', { network: ['tcp', 'udp'], proxy: ['middle', 'other'] })),
      ['a', 'b']);
    assert.deepEqual(ids(l.filterConnections([a, b], '', { rule: [l.connectionRule(a.connection)] })), ['a']);
    assert.deepEqual(l.filterConnections([], '', { network: ['tcp'] }), []);
    const many = Array.from({ length: 15 }, (_, i) => row(`${i}`, { metadata: { network: `n${i}` } }));
    const frequent = row('frequent', { metadata: { network: 'n14' } });
    const options = l.connectionFacetOptions([...many, frequent], 'network', ['n13', 'missing']);
    assert.equal(options[0], 'n14');
    assert.equal(options.length, 14);
    assert.ok(options.includes('n13') && options.includes('missing'));
    assert.deepEqual(l.connectionFacetOptions([a], 'proxy', []), ['exit', 'middle']);
  });

  run('IPv6 endpoints and grouping retain raw host, full rule, chain exit and first appearance', (h, l) => {
    assert.equal(l.diagnosticEndpoint('2001:db8::1', '443'), '[2001:db8::1]:443');
    assert.equal(l.diagnosticEndpoint('[::1]', '80'), '[::1]:80');
    assert.equal(l.diagnosticEndpoint('192.0.2.1', ''), '192.0.2.1');
    assert.equal(l.diagnosticEndpoint('', '443'), '');
    const a = row('a', { metadata: { host: '' }, rule: 'DOMAIN', rulePayload: 'example.test', chains: ['EXIT', 'INNER'] });
    const b = row('b', { metadata: { host: 'Raw.Host' }, chains: ['EXIT'] });
    const c = row('c', { metadata: { host: '' } });
    assert.equal(l.connectionRule(a.connection), 'DOMAIN(example.test)');
    const groups = l.groupConnections([a, b, c], 'host');
    assert.deepEqual(groups.map(group => group.title), ['', 'Raw.Host']);
    assert.deepEqual(ids(groups[0].items), ['a', 'c']);
    assert.equal(groups[0].key, 'host:');
    assert.deepEqual(l.groupConnections([a, b], 'exit').map(group => ids(group.items)), [['a', 'b']]);
    assert.equal(l.groupConnections([a], 'rule')[0].title, 'DOMAIN(example.test)');
    assert.deepEqual(ids(l.groupConnections([a, b, c], 'none')[0].items), ['a', 'b', 'c']);
  });

  run('DNS matching covers answers, failures, unknown upstream and independent facets', (h, l) => {
    const hit = dns('hit', { cached: true, upstream: 'tcp://resolver', initiator: 'proxy' });
    const failed = dns('failed', { domain: 'Missing.Test', type: 'AAAA', rcode: 'NXDOMAIN',
      answers: [], error: 'lookup refused', initiator: 'rule' });
    assert.deepEqual(ids(l.filterDns([hit, failed], 'MISSING AAAA refused rule NXDOMAIN', {})), ['failed']);
    assert.deepEqual(ids(l.filterDns([hit, failed], 'resolver 192.0.2.4', {})), ['hit']);
    assert.deepEqual(ids(l.filterDns([hit, failed], '', { cache: ['true'], initiator: ['proxy', 'direct'] })), ['hit']);
    assert.deepEqual(ids(l.filterDns([hit, failed], '', { cache: ['false'], rcode: ['NXDOMAIN'] })), ['failed']);
    assert.deepEqual(l.filterDns([failed], '—', {}), []);
    assert.deepEqual(ids(l.sortDns([hit, failed], { column: 'upstream', direction: 'asc' })), ['failed', 'hit']);
    assert.deepEqual(l.dnsFacetOptions([hit, failed], 'cache', []), ['true', 'false']);
    assert.deepEqual(l.dnsFacetOptions([], 'type', ['TXT']), ['TXT']);
    const resultSorted = l.sortDns([dns('answer', { answers: ['z'] }), failed], { column: 'result', direction: 'asc' });
    assert.deepEqual(ids(resultSorted), ['failed', 'answer']);
  });

  run('three-state sorting uses recommended direction, preserves ties and never mutates input', (h, l) => {
    let sort = l.nextRecordSort({ column: '', direction: '' }, 'traffic', true);
    assert.equal(sort.direction, 'desc');
    sort = l.nextRecordSort(sort, 'traffic', true);
    assert.equal(sort.direction, 'asc');
    sort = l.nextRecordSort(sort, 'traffic', true);
    assert.deepEqual(sort, { column: '', direction: '' });
    assert.equal(l.nextRecordSort(sort, 'target', false).direction, 'asc');
    const records = [row('first', { upload: 4, metadata: { host: 'z' } }),
      row('second', { download: 4, metadata: { host: 'A' } }), row('third', { upload: 10 })];
    assert.deepEqual(ids(l.sortConnections(records, { column: 'traffic', direction: 'desc' })), ['third', 'first', 'second']);
    assert.deepEqual(ids(l.sortConnections(records, { column: 'target', direction: 'asc' })), ['second', 'third', 'first']);
    assert.deepEqual(ids(l.sortConnections(records, { column: '', direction: '' })), ids(records));
    const timed = [row('old'), row('new', { start: '1970-01-01T00:00:01Z' })];
    assert.deepEqual(ids(l.sortConnections(timed, { column: 'time', direction: 'desc' })), ['new', 'old']);
    const speeds = [row('slow', {}, { downloadSpeed: 5, duration: 2000 }), row('fast', {}, { downloadSpeed: 20, duration: 1 })];
    assert.deepEqual(ids(l.sortConnections(speeds, { column: 'downloadSpeed', direction: 'desc' })), ['fast', 'slow']);
    assert.deepEqual(ids(l.sortConnections(speeds, { column: 'duration', direction: 'desc' })), ['slow', 'fast']);
    assert.deepEqual(ids(records), ['first', 'second', 'third']);
    assert.deepEqual(ids(l.sortDns([dns('a', { delay: 10 }), dns('b', { delay: 50 }), dns('c', { delay: 50 })],
      { column: 'elapsed', direction: 'desc' })), ['b', 'c', 'a']);
  });

  run('speed samples use actual intervals, retain sub500 baseline, clamp rollback, decay and reset', (h, l) => {
    const ranker = new l.TrackerSpeedRanker();
    let ranked = ranker.rank([connection('a')], 1000);
    assert.equal(ranked[0].uploadSpeed, 0);
    assert.equal(ranked[0].duration, 1000);
    const original = ranked[0];
    assert.equal(ranker.rank([connection('a')], 1000)[0], original);
    ranked = ranker.rank([connection('a', { upload: 100 })], 1400);
    assert.equal(ranked[0].uploadSpeed, 0);
    ranked = ranker.rank([connection('a', { upload: 150, download: 75 })], 2500);
    assert.equal(ranked[0].uploadSpeed, 100);
    assert.equal(ranked[0].downloadSpeed, 50);
    assert.equal(ranked[0].rankSpeed, 75);
    ranked = ranker.rank([connection('a', { upload: 1, download: 0 })], 3500);
    assert.equal(ranked[0].uploadSpeed, 0);
    assert.equal(ranked[0].downloadSpeed, 0);
    assert.equal(ranked[0].rankSpeed, 37.5);
    for (let i = 0; i < 6; i++) ranked = ranker.rank([connection('a', { upload: 1 })], 4500 + i * 1000);
    assert.equal(ranked[0].rankSpeed, 0);
    ranker.reset();
    assert.equal(ranker.rank([connection('a', { upload: 9000 })], 20000)[0].uploadSpeed, 0);
  });

  run('speed buckets preserve previous active positions then use traffic/start/id tie breakers', (h, l) => {
    const ranker = new l.TrackerSpeedRanker();
    assert.deepEqual(ids(ranker.rank([connection('b'), connection('a', { upload: 10 })], 1000)), ['a', 'b']);
    let ranked = ranker.rank([connection('b', { upload: 120 }), connection('a', { upload: 110 })], 2000);
    assert.deepEqual(ids(ranked), ['a', 'b']);
    assert.equal(ranked[0].rankSpeed, 50);
    assert.equal(ranked[1].rankSpeed, 60);
    ranked = ranker.rank([connection('a', { upload: 110 }), connection('b', { upload: 2000 })], 3000);
    assert.equal(ranked[0].key, 'b');
    ranker.reset();
    assert.deepEqual(ids(ranker.rank([connection('z'), connection('a'), connection('new', { start: '1970-01-01T00:00:01Z' })],
      2000)), ['new', 'a', 'z']);
    ranker.rank([], 4000);
    assert.equal(ranker.rank([connection('b', { upload: 100000 })], 5000)[0].uploadSpeed, 0);
  });

  run('columns switch at actual 720/1000/1200 vp and honor measured localized labels', (h, l) => {
    assert.deepEqual(l.recordColumns('requests', 719.99, {}), []);
    assert.deepEqual(l.recordColumns('requests', 720, {}).map(c => c.id), ['time', 'target', 'rule', 'exit', 'traffic']);
    assert.deepEqual(l.recordColumns('requests', 1000, {}).map(c => c.id),
      ['time', 'target', 'protocol', 'rule', 'exit', 'download', 'upload']);
    assert.ok(!l.recordColumns('connections', 999.99, {}).some(c => c.id === 'rule'));
    assert.ok(l.recordColumns('connections', 1000, {}).some(c => c.id === 'rule'));
    assert.ok(!l.recordColumns('connections', 1199.99, {}).some(c => c.id === 'duration'));
    const full = l.recordColumns('connections', 1200, { protocol: 113, download: 130, upload: 70 });
    assert.equal(full.find(c => c.id === 'protocol').width, 113);
    assert.equal(full.find(c => c.id === 'download').width, 130);
    assert.equal(full.find(c => c.id === 'upload').width, 88);
    assert.equal(full.at(-1).id, 'duration');
    assert.equal(l.recordColumns('requests', 1000, { download: 150 }).find(c => c.id === 'download').width, 100);
    assert.ok(!l.recordColumns('dns', 999.99, {}).some(c => c.id === 'upstream'));
    assert.equal(l.recordColumns('dns', 1000, {}).at(-1).id, 'upstream');
  });

  run('Prism widths allocate flex, borrow right donors, enforce minimum, scale shrinking and reset', (h, l) => {
    const column = (id, width, flex = 0, resizable = true) =>
      ({ id, width, flex, resizable, numeric: false, descending: false });
    const columns = [column('a', 100), column('b', 0, 2), column('c', 0, 1)];
    assert.deepEqual(l.tableColumnWidths(columns, 400), [100, 200, 100]);
    const resized = l.resizedTableColumns(columns, [100, 200, 100], {}, 0, 180);
    assert.deepEqual(resized, { a: 280, b: 48, c: 72 });
    assert.deepEqual(l.tableColumnWidths(columns, 400, resized), [280, 48, 72]);
    const shrunk = l.tableColumnWidths(columns, 200, resized);
    assert.deepEqual(shrunk, [140, 24, 36]);
    assert.deepEqual(l.resizedTableColumns(columns, [100, 200, 100], {}, 0, -1000), { a: 48, b: 252 });
    const withFixed = [column('a', 100), column('b', 100), column('fixed', 70, 0, false), column('d', 100)];
    assert.deepEqual(l.resizedTableColumns(withFixed, [100, 100, 70, 100], {}, 0, 200), { a: 204, b: 48, d: 48 });
    assert.deepEqual(l.tableColumnWidths(columns, 400, {}), [100, 200, 100]);
    const partial = l.tableColumnWidths(columns, 250, { a: 200 });
    closeTo(partial[0], 200 * 250 / 296);
    closeTo(partial.reduce((a, b) => a + b, 0), 250);
    const unchanged = { a: 120 };
    l.resizedTableColumns(columns, [100, 200, 100], unchanged, 0, 10);
    assert.deepEqual(unchanged, { a: 120 });
  });

  run('preferences independently default malformed fields and discard unrelated/sensitive keys', async h => {
    const p = h.load('features/tools/RecordPreferences.ets');
    const values = h.controls.preferences;
    values.set('diagnostics.requestFeed', 'invalid');
    values.set('diagnostics.grouping', 'host');
    values.set('diagnostics.columnWidths.requests', JSON.stringify({ target: 99, rule: 47, time: '80', domain: 600 }));
    values.set('diagnostics.columnWidths.connections', '{');
    values.set('diagnostics.columnWidths.dns', JSON.stringify({ domain: 160, elapsed: 90, query: 'secret.test' }));
    let snapshot = await p.loadRecordPreferences(h.context);
    assert.equal(snapshot.feed, 'live');
    assert.equal(snapshot.grouping, 'host');
    assert.deepEqual(snapshot.requests, { target: 99 });
    assert.deepEqual(snapshot.connections, {});
    assert.deepEqual(snapshot.dns, { domain: 160, elapsed: 90 });
    values.set('diagnostics.columnWidths.dns', 'null');
    values.set('diagnostics.grouping', false);
    values.set('diagnostics.requestFeed', 'recent');
    snapshot = await p.loadRecordPreferences(h.context);
    assert.equal(snapshot.feed, 'recent');
    assert.equal(snapshot.grouping, 'none');
    assert.deepEqual(snapshot.dns, {});
  });

  run('preference writes serialize, capture caller widths and persist only approved keys', async h => {
    const p = h.load('features/tools/RecordPreferences.ets');
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    const seen = [];
    h.controls.beforePreferenceFlush = async () => {
      seen.push(new Map(h.controls.preferences));
      if (seen.length === 1) await gate;
    };
    const widths = { target: 150, traffic: 90, query: 999 };
    const first = p.saveRecordColumnWidths(h.context, 'requests', widths);
    widths.target = 400;
    const second = p.saveRecordFeed(h.context, 'recent');
    const third = p.saveRecordGrouping(h.context, 'exit');
    await h.flush();
    assert.equal(seen.length, 1);
    assert.equal(h.controls.preferences.has('diagnostics.requestFeed'), false);
    release();
    await Promise.all([first, second, third]);
    assert.equal(seen.length, 3);
    assert.deepEqual(JSON.parse(h.controls.preferences.get('diagnostics.columnWidths.requests')), { target: 150, traffic: 90 });
    assert.equal(h.controls.preferences.get('diagnostics.requestFeed'), 'recent');
    assert.equal(h.controls.preferences.get('diagnostics.grouping'), 'exit');
    assert.deepEqual([...h.controls.preferences.keys()].sort(),
      ['diagnostics.columnWidths.requests', 'diagnostics.grouping', 'diagnostics.requestFeed']);
  });

  run('failed preference flush restores cached value before queued unrelated saves', async h => {
    const p = h.load('features/tools/RecordPreferences.ets');
    h.controls.preferences.set('diagnostics.requestFeed', 'live');
    h.controls.preferenceFlushFailures = 1;
    const failed = p.saveRecordFeed(h.context, 'recent');
    const failure = assert.rejects(failed, { message: 'diagnostics_preferences_failed' });
    const next = p.saveRecordGrouping(h.context, 'rule');
    await failure;
    await next;
    assert.equal(h.controls.preferences.get('diagnostics.requestFeed'), 'live');
    assert.equal(h.controls.preferences.get('diagnostics.grouping'), 'rule');
    assert.equal((await p.loadRecordPreferences(h.context)).feed, 'live');
    h.controls.preferenceGetError = true;
    await assert.rejects(p.loadRecordPreferences(h.context), { message: 'diagnostics_preferences_failed' });
    h.controls.preferenceGetError = false;
    await p.saveRecordFeed(h.context, 'recent');
    assert.equal((await p.loadRecordPreferences(h.context)).feed, 'recent');
  });
}

registerToolsLogicTests(createToolsHarness);

test('store速度只用sampledAt，空delta归零，重连同ID的大累计量不得跨断流计算', async () => toolsCase(async h => {
  const { store, socket } = await onlineTools(h, 'connections', { live: [toolConnection('active')] });
  store.select('active');
  assert.equal(store.selected.uploadSpeed, 0);
  socket.emit(toolFrame('connections', 'delta', 2, { traffic: [{ id: 'active', upload: 1000, download: 2000 }] }));
  assert.equal(store.selected.uploadSpeed, 1000);
  assert.equal(store.selected.downloadSpeed, 2000);
  socket.emit(toolFrame('connections', 'delta', 3));
  assert.equal(store.selected.uploadSpeed, 0);
  assert.equal(store.selected.downloadSpeed, 0);
  socket.disconnect();
  assert.equal(store.selected, undefined);
  assert.equal(store.totalRecords, 0);
  await h.advance(2000);
  const next = h.sockets.at(-1);
  next.open();
  next.emit(toolFrame('connections', 'snapshot', 1, {
    sessionId: 'session-b', sampledAt: Date.parse('2026-01-01T00:10:00Z'),
    live: [toolConnection('active', { upload: 1000000, download: 2000000 })]
  }));
  assert.equal(store.selected.uploadSpeed, 0);
  assert.equal(store.selected.downloadSpeed, 0);
  store.setFeed('recent');
  await h.flush();
  assert.equal(store.totalRecords, 0, 'reconnected baseline must never become a recent request');
}));

test('旧代次close响应不能覆盖新代次pending动作或通知，clearCache隐藏后无迟到Toast', async () => toolsCase(async h => {
  const { store } = await onlineTools(h);
  const firstGate = deferredTools();
  h.controls.actionGate = firstGate.promise;
  const oldAction = store.closeAll();
  await h.flush();
  store.setConnection(true, 'boot-a', 2);
  await h.flush();
  h.sockets.at(-1).open();
  h.sockets.at(-1).emit(toolFrame('connections', 'snapshot', 1, { configRevision: 2, sessionId: 'session-b' }));
  const secondGate = deferredTools();
  h.controls.actionGate = secondGate.promise;
  const newAction = store.closeAll();
  await h.flush();
  firstGate.resolve();
  await oldAction;
  assert.equal(store.notice, '');
  assert.equal(store.actionPending, true);
  secondGate.resolve();
  await newAction;
  assert.equal(store.notice, 'closed');
  assert.equal(store.actionPending, false);
  assert.equal(h.requests[0].body.expectedConfigRevision, 1);
  assert.equal(h.requests[1].body.expectedConfigRevision, 2);
  const dnsStore = (await onlineTools(h, 'dns')).store;
  const dnsGate = deferredTools();
  h.controls.actionGate = dnsGate.promise;
  const clear = dnsStore.clearCache();
  await h.flush();
  dnsStore.setVisible(false);
  dnsGate.resolve();
  await clear;
  assert.equal(dnsStore.notice, '');
  assert.equal(dnsStore.actionPending, false);
}));
