// 执行真实 ArkTS 存储与安装逻辑；替身仅提供平台文件/资源 API 和确定性故障。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const etsDir = fileURLToPath(new URL('../entry/src/main/ets/', import.meta.url));

function platformError(error) {
  if (error.code === 'ENOENT') error.code = 13900002;
  throw error;
}

// 后续 Store 用例可复用 load、controls、geo 和真实临时目录，不替换产品存储函数。
function createResourcesHarness(dir, timers = {}) {
  const modules = new Map();
  const descriptors = new Map();
  const controls = { fail: undefined, shortWrite: false, writeGate: undefined, writing: false, readGate: undefined };
  function check(operation, file) {
    if (controls.fail?.(operation, file)) throw Object.assign(new Error('fixture I/O failure'), { code: 13900012 });
  }
  const fileIo = {
    OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, TRUNC: fs.constants.O_TRUNC },
    async readText(file) {
      check('read', file);
      try {
        const text = await fsp.readFile(file, 'utf8');
        await controls.readGate?.(file);
        return text;
      } catch (error) { platformError(error); }
    },
    async listFile(file) { check('list', file); return (await fsp.readdir(file)).reverse(); },
    async stat(file) {
      check('stat', file);
      try {
        const stat = await fsp.stat(file);
        return { size: stat.size, mtime: Math.floor(stat.mtimeMs / 1000), isFile: () => stat.isFile() };
      } catch (error) { platformError(error); }
    },
    async open(file, flags) {
      check('open', file);
      const handle = await fsp.open(file, flags, 0o600);
      descriptors.set(handle.fd, file);
      return { fd: handle.fd, handle };
    },
    async write(fd, data) {
      check('write', descriptors.get(fd));
      controls.writing = true;
      await controls.writeGate;
      const bytes = Buffer.from(data);
      const length = controls.shortWrite ? Math.max(0, bytes.length - 1) : bytes.length;
      return new Promise((resolve, reject) => fs.write(fd, bytes, 0, length, null,
        (error, written) => error ? reject(error) : resolve(written)));
    },
    async close(file) {
      const name = descriptors.get(file.fd);
      descriptors.delete(file.fd);
      await file.handle.close();
      check('close', name);
    },
    async fsync(fd) {
      check('fsync', descriptors.get(fd));
      await new Promise((resolve, reject) => fs.fsync(fd, error => error ? reject(error) : resolve()));
    },
    async rename(from, to) { check('rename', to); await fsp.rename(from, to); },
    async unlink(file) { check('unlink', file); try { await fsp.unlink(file); } catch (error) { platformError(error); } }
  };
  const kits = {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.CoreFileKit': { fileIo },
    '@kit.ArkTS': { url: { URL: { parseURL: source => new URL(source) } }, util: {
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      TextDecoder: { create: encoding => ({ decodeToString: bytes => new TextDecoder(encoding).decode(bytes) }) }
    } }
  };
  function load(relative, bindings = {}) {
    const absolute = path.resolve(etsDir, relative);
    if (modules.has(absolute)) return modules.get(absolute).exports;
    const source = fs.readFileSync(absolute, 'utf8').replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
    const compiled = ts.transpileModule(source, { fileName: absolute.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
    const module = { exports: {} };
    modules.set(absolute, module);
    vm.runInNewContext(compiled, { module, exports: module.exports, console, setTimeout, clearTimeout,
      setInterval, clearInterval, ...timers, require(name) {
        if (name in bindings) return bindings[name];
        if (name in kits) return kits[name];
        assert.ok(name.startsWith('.'), `unexpected module ${name}`);
        return load(path.relative(etsDir, path.resolve(path.dirname(absolute), `${name}.ets`)), bindings);
      } }, { filename: absolute });
    return module.exports;
  }
  const geo = load('shared/GeoResources.ets');
  const installer = load('vpn/GeoData.ets');
  const resources = new Map([
    ['geo/VERSION', Buffer.from('bundle-v2')], ['geo/geoip.metadb', Buffer.from('bundled-mmdb')],
    ['geo/geosite.dat', Buffer.from('bundled-geosite')]
  ]);
  const context = { filesDir: dir, resourceManager: { async getRawFileContent(name) {
    const bytes = resources.get(name);
    if (bytes === undefined) throw new Error('missing rawfile');
    return new Uint8Array(bytes);
  } } };
  return { geo, installer, controls, resources, context, load };
}

async function sandbox(run) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'arkclash-geo-case-'));
  try { await run(dir, createResourcesHarness(dir)); }
  finally { await fsp.rm(dir, { recursive: true, force: true }); }
}
const plain = data => JSON.parse(JSON.stringify(data));

async function existingBundle(dir) {
  await fsp.writeFile(path.join(dir, 'geoip.metadb'), 'old-mmdb');
  await fsp.writeFile(path.join(dir, 'geosite.dat'), 'old-geosite');
  await fsp.writeFile(path.join(dir, 'geo.version'), 'bundle-v1');
}

async function managed(dir, id, isManaged = true) {
  await fsp.writeFile(path.join(dir, `geo-${id}.json`), JSON.stringify({ version: 1, managed: isManaged, lastAttemptAt: 1 }));
}

test('默认设置无需写盘，保存返回已提交revision并能完整重读', async () => sandbox(async (dir, { geo }) => {
  const initial = await geo.readGeoSettings(dir);
  assert.equal(initial.revision, 'default');
  assert.equal(initial.autoUpdate, true);
  assert.equal(initial.intervalHours, 24);
  assert.deepEqual(await fsp.readdir(dir), []);
  initial.urls.mmdb = 'https://example.com/custom.mmdb?token=private';
  initial.autoUpdate = false;
  const committed = await geo.saveGeoSettings(dir, initial);
  await geo.flushGeoSettings();
  assert.notEqual(committed.revision, 'default');
  assert.deepEqual(plain(await geo.readGeoSettings(dir)), plain(committed));
  assert.equal((await fsp.stat(path.join(dir, 'geo-settings.json'))).mode & 0o777, 0o600);
}));

test('旧revision和并发旧草稿不得覆盖队列内已提交的新URL', async () => sandbox(async (dir, { geo }) => {
  const first = geo.defaultGeoSettings();
  const stale = geo.defaultGeoSettings();
  first.urls.mmdb = 'https://example.com/new.mmdb';
  stale.urls.mmdb = 'https://example.com/stale.mmdb';
  const saved = geo.saveGeoSettings(dir, first);
  const rejected = assert.rejects(geo.saveGeoSettings(dir, stale), /geo_settings_conflict/);
  first.urls.mmdb = 'https://example.com/mutated-after-admission';
  const result = await saved;
  await rejected;
  assert.equal((await geo.readGeoSettings(dir)).urls.mmdb, result.urls.mmdb);
  assert.equal(result.urls.mmdb, 'https://example.com/new.mmdb');
  await assert.rejects(geo.flushGeoSettings(), /geo_settings_conflict/);
  await geo.saveGeoSettings(dir, result);
  await geo.flushGeoSettings();
}));

test('非法URL和间隔均不写盘，验证禁止认证、空主机、控制符与超长URL', async () => sandbox(async (dir, { geo }) => {
  for (const source of ['', 'ftp://example.com/a', 'https://u:p@example.com/a', 'https://@example.com/a',
    'https:///','https://', 'https:///example.com/a', 'https:example.com/a', 'https:/example.com/a',
    'https://example.com\\path',
    'https://example.com/\nsecret', ' https://example.com/a', `https://example.com/${'a'.repeat(2048)}`]) {
    assert.equal(geo.validateGeoUrl(source), false, source);
    const draft = geo.defaultGeoSettings();
    draft.urls.mmdb = source;
    await assert.rejects(geo.saveGeoSettings(dir, draft), /geo_invalid_url/);
    assert.deepEqual(await fsp.readdir(dir), []);
  }
  assert.equal(geo.validateGeoUrl('http://127.0.0.1:8080/a?x=y'), true);
  for (const hours of [0, -1, 1.5, 8761, NaN, Infinity, '24']) {
    const draft = geo.defaultGeoSettings();
    draft.intervalHours = hours;
    await assert.rejects(geo.saveGeoSettings(dir, draft), /geo_invalid_settings/);
    assert.deepEqual(await fsp.readdir(dir), []);
  }
}));

test('损坏设置不能普通保存覆盖，只有显式reset可恢复且不删除数据库', async () => sandbox(async (dir, { geo }) => {
  const file = path.join(dir, 'geo-settings.json');
  await fsp.writeFile(path.join(dir, 'ASN.mmdb'), 'keep-database');
  for (const invalid of ['{broken', 'null', '{}', JSON.stringify({ ...geo.defaultGeoSettings(), version: 2 }),
    JSON.stringify({ ...geo.defaultGeoSettings(), autoUpdate: 'false' })]) {
    await fsp.writeFile(file, invalid);
    await assert.rejects(geo.readGeoSettings(dir), /geo_invalid_settings/);
    await assert.rejects(geo.saveGeoSettings(dir, geo.defaultGeoSettings()), /geo_invalid_settings/);
    assert.equal(await fsp.readFile(file, 'utf8'), invalid);
  }
  const reset = await geo.resetGeoSettings(dir);
  assert.equal(reset.urls.asn, geo.GEO_DEFAULT_URLS.asn);
  assert.notEqual(reset.revision, 'default');
  assert.equal(await fsp.readFile(path.join(dir, 'ASN.mmdb'), 'utf8'), 'keep-database');
  await geo.flushGeoSettings();
}));

test('真实IO失败保留已提交设置，启动屏障报错而读盘仍返回旧值', async () => sandbox(async (dir, { geo, controls }) => {
  const initial = await geo.saveGeoSettings(dir, geo.defaultGeoSettings());
  const previous = await fsp.readFile(path.join(dir, 'geo-settings.json'), 'utf8');
  for (const operation of ['open', 'write', 'close', 'rename']) {
    controls.fail = (op, file) => op === operation && file.includes('geo-settings.json');
    const draft = { ...initial, intervalHours: 48 };
    await assert.rejects(geo.saveGeoSettings(dir, draft), /geo_io/);
    await assert.rejects(geo.flushGeoSettings(), /geo_io/);
    assert.equal(await fsp.readFile(path.join(dir, 'geo-settings.json'), 'utf8'), previous);
    controls.fail = undefined;
    assert.equal((await geo.readGeoSettings(dir)).revision, initial.revision);
  }
  controls.fail = (op, file) => op === 'read' && file.endsWith('geo-settings.json');
  await assert.rejects(geo.readGeoSettings(dir), /geo_io/);
  controls.fail = undefined;
  await geo.resetGeoSettings(dir);
}));

test('文件列表缺失状态、毫秒mtime、排序和大小写与固定路径约定一致', async () => sandbox(async (dir, { geo }) => {
  let items = await geo.readGeoFileInfos(dir);
  assert.deepEqual(plain(items.map(item => [item.id, item.fileName, item.exists, item.size, item.modifiedAt])), [
    ['mmdb', 'geoip.metadb', false, 0, 0], ['asn', 'ASN.mmdb', false, 0, 0],
    ['geoip', 'GeoIP.dat', false, 0, 0], ['geosite', 'geosite.dat', false, 0, 0]
  ]);
  await fsp.mkdir(path.join(dir, 'Country.mmdb'));
  await fsp.writeFile(path.join(dir, 'geoip.metadb'), 'later');
  await fsp.writeFile(path.join(dir, 'GEOIP.DB'), 'first-regular');
  await fsp.writeFile(path.join(dir, 'AsN.MmDb'), 'asn');
  await fsp.writeFile(path.join(dir, 'GEOSITE.DAT'), 'site');
  const seconds = 1700000000;
  await fsp.utimes(path.join(dir, 'GEOIP.DB'), seconds, seconds);
  items = await geo.readGeoFileInfos(dir);
  assert.equal(items[0].fileName, 'GEOIP.DB');
  assert.equal(items[0].size, Buffer.byteLength('first-regular'));
  assert.equal(items[0].modifiedAt, seconds * 1000);
  assert.equal(items[1].fileName, 'AsN.MmDb');
  assert.equal(items[2].exists, false);
  assert.equal(items[3].fileName, 'GEOSITE.DAT');
}));

test('元数据缺失与损坏可区分，权限/stat/list故障不伪装成未下载', async () => sandbox(async (dir, { geo, controls }) => {
  assert.equal(await geo.readGeoMetadata(dir, 'mmdb'), undefined);
  for (const invalid of ['{bad', 'null', '{"version":1,"managed":true}',
    '{"version":1,"managed":true,"lastAttemptAt":-1}']) {
    await fsp.writeFile(path.join(dir, 'geo-mmdb.json'), invalid);
    await assert.rejects(geo.readGeoMetadata(dir, 'mmdb'), /geo_metadata_invalid/);
    assert.equal((await geo.readGeoFileInfos(dir))[0].error, 'geo_metadata_invalid');
  }
  controls.fail = (op, file) => op === 'read' && file.endsWith('geo-mmdb.json');
  await assert.rejects(geo.readGeoMetadata(dir, 'mmdb'), /geo_io/);
  assert.equal((await geo.readGeoFileInfos(dir))[0].error, 'geo_io');
  controls.fail = undefined;
  await fsp.writeFile(path.join(dir, 'ASN.mmdb'), 'asn');
  controls.fail = (op, file) => op === 'stat' && file.endsWith('ASN.mmdb');
  assert.equal((await geo.readGeoFileInfos(dir))[1].error, 'geo_io');
  controls.fail = op => op === 'list';
  await assert.rejects(geo.readGeoFileInfos(dir), /geo_io/);
}));

test('bundle升级替换未接管资源，只打包原两项，版本相同不重复复制', async () => sandbox(async (dir, h) => {
  await existingBundle(dir);
  assert.equal(await h.installer.installGeoData(h.context, dir), 2);
  assert.equal(await fsp.readFile(path.join(dir, 'geoip.metadb'), 'utf8'), 'bundled-mmdb');
  assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'bundled-geosite');
  assert.equal(await fsp.readFile(path.join(dir, 'geo.version'), 'utf8'), 'bundle-v2');
  assert.equal(await h.installer.installGeoData(h.context, dir), 0);
  assert.deepEqual((await fsp.readdir(dir)).sort(), ['geo.version', 'geoip.metadb', 'geosite.dat']);
}));

test('升级保护managed与损坏元数据，大小写别名不会另建重复文件', async () => sandbox(async (dir, h) => {
  await existingBundle(dir);
  await fsp.rename(path.join(dir, 'geoip.metadb'), path.join(dir, 'Country.mmdb'));
  await managed(dir, 'mmdb');
  await fsp.writeFile(path.join(dir, 'geo-geosite.json'), '{corrupt');
  assert.equal(await h.installer.installGeoData(h.context, dir), 0);
  assert.equal(await fsp.readFile(path.join(dir, 'Country.mmdb'), 'utf8'), 'old-mmdb');
  assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'old-geosite');
  await assert.rejects(fsp.stat(path.join(dir, 'geoip.metadb')), { code: 'ENOENT' });
  assert.equal(await fsp.readFile(path.join(dir, 'geo.version'), 'utf8'), 'bundle-v2');
}));

test('相同bundle版本也恢复单项缺失，即使其元数据已接管或损坏', async () => sandbox(async (dir, h) => {
  await existingBundle(dir);
  await fsp.writeFile(path.join(dir, 'geo.version'), 'bundle-v2');
  await managed(dir, 'mmdb');
  await fsp.unlink(path.join(dir, 'geoip.metadb'));
  assert.equal(await h.installer.installGeoData(h.context, dir), 1);
  assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'old-geosite');
  await fsp.writeFile(path.join(dir, 'geo-geosite.json'), '{bad');
  await fsp.unlink(path.join(dir, 'geosite.dat'));
  assert.equal(await h.installer.installGeoData(h.context, dir), 1);
  assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'bundled-geosite');
}));

test('复制短写与write/close/fsync/rename故障不破坏活动文件、不更新stamp且清理临时文件', async () => {
  for (const fault of ['short', 'open', 'write', 'close', 'fsync', 'rename']) {
    await sandbox(async (dir, h) => {
      await existingBundle(dir);
      h.controls.shortWrite = fault === 'short';
      h.controls.fail = (op, file) => op === fault && file.includes('geoip.metadb');
      await assert.rejects(h.installer.installGeoData(h.context, dir));
      assert.equal(await fsp.readFile(path.join(dir, 'geoip.metadb'), 'utf8'), 'old-mmdb');
      assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'old-geosite');
      assert.equal(await fsp.readFile(path.join(dir, 'geo.version'), 'utf8'), 'bundle-v1');
      assert.equal((await fsp.readdir(dir)).some(name => name.endsWith('.tmp')), false);
    });
  }
});

test('第二个资源复制中断保持旧stamp，重试可完成；元数据IO错误中止而不覆盖', async () => sandbox(async (dir, h) => {
  await existingBundle(dir);
  h.controls.fail = (op, file) => op === 'write' && file.includes('geosite.dat');
  await assert.rejects(h.installer.installGeoData(h.context, dir));
  assert.equal(await fsp.readFile(path.join(dir, 'geo.version'), 'utf8'), 'bundle-v1');
  assert.equal(await fsp.readFile(path.join(dir, 'geosite.dat'), 'utf8'), 'old-geosite');
  assert.equal((await fsp.readdir(dir)).some(name => name.endsWith('.tmp')), false);
  h.controls.fail = (op, file) => op === 'read' && file.endsWith('geo-mmdb.json');
  await assert.rejects(h.installer.installGeoData(h.context, dir), /geo_io/);
  h.controls.fail = undefined;
  assert.equal(await h.installer.installGeoData(h.context, dir), 2);
}));

test('未包含bundle资产的开发包不创建数据库或版本标记', async () => sandbox(async (dir, h) => {
  h.resources.delete('geo/VERSION');
  assert.equal(await h.installer.installGeoData(h.context, dir), 0);
  assert.deepEqual(await fsp.readdir(dir), []);
}));

// 平台 HTTP/WebSocket 替身执行真实 Controller、ControllerSocket、客户端与 Store。
function resourceClock() {
  let now = 1000000;
  let next = 0;
  const timers = new Map();
  const schedule = (run, delay, repeat) => {
    const id = ++next;
    timers.set(id, { run, delay, repeat, at: now + delay });
    return id;
  };
  return {
    timers,
    bindings: {
      Date: class extends Date { static now() { return now; } },
      setTimeout: (run, delay) => schedule(run, delay, false),
      clearTimeout: id => timers.delete(id),
      setInterval: (run, delay) => schedule(run, delay, true),
      clearInterval: id => timers.delete(id)
    },
    advance(milliseconds) {
      now += milliseconds;
      for (const [id, timer] of [...timers]) {
        if (timer.at > now) continue;
        if (timer.repeat) timer.at = now + timer.delay;
        else timers.delete(id);
        timer.run();
      }
    }
  };
}

function deferredResource() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

async function untilResource(predicate) {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    assert.ok(Date.now() < deadline, 'resource fixture did not settle');
    await new Promise(resolve => setImmediate(resolve));
  }
}

function resourceSnapshot(revision = 1, settingsRevision = 'default', bootId = 'boot-a') {
  return { bootId, revision, settingsRevision, items: ['mmdb', 'asn', 'geoip', 'geosite'].map(id => ({
    id, fileName: `${id}.fixture`, exists: false, size: 0, modifiedAt: 0,
    phase: 'idle', operationId: '', outcome: 'none', error: ''
  })) };
}

function resourceOperation(snapshot, id, operationId, phase = 'updating', outcome = 'none', error = '') {
  Object.assign(snapshot.items.find(item => item.id === id), { operationId, phase, outcome, error });
  return snapshot;
}

async function resourceStoreCase(run) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'arkclash-geo-store-'));
  const clock = resourceClock();
  const h = createResourcesHarness(dir, clock.bindings);
  const sockets = [];
  const requests = [];
  const server = {
    snapshot: resourceSnapshot(), applyError: undefined, getGate: undefined, getStarted: false,
    applyGate: undefined, applyStarted: false, update: undefined, destroyed: 0
  };
  const response = (snapshot, responseCode = 200) => ({ responseCode, result: JSON.stringify(snapshot) });
  const network = {
    http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0 },
      createHttp: () => ({
        async request(address, options) {
          assert.equal(options.header.Authorization, 'Bearer fixture-controller-secret');
          const route = new URL(address).pathname;
          const body = options.extraData === undefined ? undefined : JSON.parse(options.extraData);
          requests.push({ route, method: options.method, body });
          if (route === '/arkclash/geo') {
            assert.equal(options.method, 'GET');
            const initial = plain(server.snapshot);
            server.getStarted = true;
            await server.getGate;
            return response(initial);
          }
          assert.equal(options.method, 'POST');
          assert.equal(body.expectedBootId, server.snapshot.bootId);
          if (route === '/arkclash/geo/settings') {
            server.applyStarted = true;
            await server.applyGate;
            if (server.applyError) return response({ message: server.applyError }, 503);
            const settings = JSON.parse(await fsp.readFile(path.join(dir, 'geo-settings.json'), 'utf8'));
            assert.equal(body.revision, settings.revision);
            server.snapshot = { ...plain(server.snapshot), revision: server.snapshot.revision + 1,
              settingsRevision: body.revision };
            return response(server.snapshot);
          }
          assert.equal(route, '/arkclash/geo/update');
          assert.ok(server.update, 'unexpected update request');
          return server.update(body, response);
        },
        destroy() { ++server.destroyed; }
      })
    },
    webSocket: {
      createWebSocket() {
        const callbacks = new Map();
        const socket = {
          closed: false,
          on(name, callback) { callbacks.set(name, callback); },
          off(name) { callbacks.delete(name); },
          async connect(address, options) {
            assert.equal(address, 'ws://127.0.0.1:19090/arkclash/geo/events');
            assert.equal(options.header.Authorization, 'Bearer fixture-controller-secret');
            socket.address = address;
          },
          async close() { socket.closed = true; },
          emit(snapshot) { callbacks.get('message')?.(undefined, JSON.stringify({ type: 'geo', snapshot })); },
          disconnect() { callbacks.get('close')?.(); }
        };
        sockets.push(socket);
        return socket;
      }
    }
  };
  await fsp.writeFile(path.join(dir, 'runtime.json'), JSON.stringify({
    secret: 'fixture-controller-secret', stack: 'mixed', mode: 'rule'
  }));
  const { ResourcesStore } = h.load('features/resources/Resources.ets', { '@kit.NetworkKit': network });
  const store = new ResourcesStore();
  const fixture = {
    ...h, dir, store, server, sockets, requests, clock,
    emit(snapshot) {
      server.snapshot = plain(snapshot);
      sockets.at(-1).emit(snapshot);
    },
    async online() {
      store.setConnection(true, server.snapshot.bootId);
      store.setVisible(true);
      await store.load(h.context);
      await untilResource(() => sockets.length > 0 && store.canSync);
    }
  };
  try { await run(fixture); }
  finally {
    store.setVisible(false);
    assert.equal(clock.timers.size, 0, 'hidden Store/socket must release all timers');
    assert.ok(sockets.every(socket => socket.closed), 'hidden Store must close each platform socket');
    await fsp.rm(dir, { recursive: true, force: true });
  }
}

test('Store离线读取和编辑真实文件，四项对象稳定且隐藏无订阅和时钟', async () => resourceStoreCase(async h => {
  await fsp.writeFile(path.join(h.dir, 'ASN.mmdb'), 'offline-asn');
  await h.store.load(h.context);
  const items = [...h.store.items];
  assert.equal(h.store.items[1].exists, true);
  assert.equal(h.store.items[0].exists, false);
  assert.equal(h.store.canSync, false);
  assert.equal(h.clock.timers.size, 0);
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(h.clock.timers.size, 1);
  const before = h.store.now;
  h.clock.advance(60000);
  assert.equal(h.store.now, before + 60000);
  await h.store.saveUrl('asn', 'https://offline.example/asn.mmdb');
  assert.equal(h.store.notice.kind, 'saved');
  h.store.clearNotice();
  await h.store.saveInterval(48);
  const disk = await h.geo.readGeoSettings(h.dir);
  assert.equal(disk.urls.asn, 'https://offline.example/asn.mmdb');
  assert.equal(disk.intervalHours, 48);
  assert.equal(h.requests.length, 0);
  assert.equal(h.sockets.length, 0);
  assert.ok(h.store.items.every((item, index) => item === items[index]));
  h.store.setVisible(false);
  const hiddenNow = h.store.now;
  h.clock.advance(120000);
  assert.equal(h.store.now, hiddenNow);
  assert.equal(h.store.notice, undefined);
}));

test('保存RPC失败仅待应用，恢复页面尝试一次，成功快照才允许更新且错误不泄密', async () => resourceStoreCase(async h => {
  await h.online();
  h.server.applyError = 'network https://private.example/?token=secret fixture-controller-secret';
  await h.store.saveAutoUpdate(true);
  assert.equal(h.store.settings.autoUpdate, true);
  assert.equal((await h.geo.readGeoSettings(h.dir)).autoUpdate, true);
  assert.equal(h.store.pendingApply, true);
  assert.equal(h.store.canSync, false);
  assert.equal(h.store.error, 'geo_download_failed');
  assert.equal(h.store.notice.kind, 'pending');
  const applied = () => h.requests.filter(request => request.route.endsWith('/settings')).length;
  const count = applied();
  h.clock.advance(120000);
  assert.equal(applied(), count);
  await assert.rejects(h.store.sync(['mmdb']), /geo_stale_boot/);
  h.store.setVisible(false);
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(applied(), count + 1);
  assert.equal(h.store.notice, undefined);
  assert.equal(h.store.pendingApply, true);
  h.store.setVisible(false);
  h.server.applyError = undefined;
  const gate = deferredResource();
  h.server.applyGate = gate.promise;
  h.server.applyStarted = false;
  h.store.setVisible(true);
  const load = h.store.load(h.context);
  await untilResource(() => h.server.applyStarted);
  assert.equal(h.store.canSync, false);
  gate.resolve();
  await load;
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.pendingApply, false);
  assert.equal(h.server.destroyed, h.requests.length);
}));

test('旧Sheet revision拒绝覆盖并重读已提交值，失败只抛表单错误且保存互斥', async () => resourceStoreCase(async h => {
  h.store.setVisible(true);
  await h.store.load(h.context);
  const oldRevision = h.store.settings.revision;
  await h.store.saveUrl('mmdb', 'https://first.example/mmdb');
  h.store.clearNotice();
  const revision = h.store.settings.revision;
  await assert.rejects(h.store.saveUrl('mmdb', 'https://stale.example/mmdb', oldRevision), /geo_settings_conflict/);
  assert.equal(h.store.notice, undefined);
  assert.equal(h.store.settings.revision, revision);
  assert.equal(h.store.settings.urls.mmdb, 'https://first.example/mmdb');
  await assert.rejects(h.store.saveInterval(72, oldRevision), /geo_settings_conflict/);
  const external = await h.geo.readGeoSettings(h.dir);
  external.urls.asn = 'https://external.example/asn';
  const committed = await h.geo.saveGeoSettings(h.dir, external);
  await assert.rejects(h.store.saveInterval(72), /geo_settings_conflict/);
  assert.equal(h.store.settings.revision, committed.revision);
  assert.equal(h.store.settings.urls.asn, 'https://external.example/asn');
  const gate = deferredResource();
  h.controls.writeGate = gate.promise;
  const save = h.store.saveInterval(36);
  await untilResource(() => h.controls.writing);
  await assert.rejects(h.store.saveAutoUpdate(false), /geo_invalid_settings/);
  gate.resolve();
  await save;
  assert.equal(h.store.settings.intervalHours, 36);
  assert.equal(h.store.settings.autoUpdate, true);
  h.store.clearNotice();
  await assert.rejects(h.store.saveUrl('asn', 'ftp://invalid.example/asn'), /geo_invalid_url/);
  assert.equal(h.store.notice, undefined);
}));

test('乱序GET、推送和受理不能回退；极快完成在受理前被下一任务替换仍反馈原操作', async () => resourceStoreCase(async h => {
  const get = deferredResource();
  h.server.getGate = get.promise;
  h.store.setConnection(true, 'boot-a');
  h.store.setVisible(true);
  const load = h.store.load(h.context);
  await untilResource(() => h.server.getStarted && h.sockets.length === 1);
  h.emit(resourceSnapshot(8));
  assert.equal(h.store.canSync, true);
  h.emit(resourceOperation(resourceSnapshot(7), 'mmdb', 'old', 'updating'));
  h.sockets[0].emit(resourceOperation(resourceSnapshot(90, 'default', 'wrong-boot'), 'mmdb', 'wrong', 'updating'));
  get.resolve();
  await load;
  assert.equal(h.store.items[0].phase, 'idle');
  const admission = deferredResource();
  const accepted = resourceOperation(resourceSnapshot(9), 'mmdb', 'fast', 'queued');
  h.server.update = async (_body, response) => { await admission.promise; return response(accepted, 202); };
  const sync = h.store.sync(['mmdb']);
  await untilResource(() => h.requests.some(request => request.route.endsWith('/update')));
  h.emit(resourceOperation(resourceSnapshot(10), 'mmdb', 'fast', 'idle', 'updated'));
  h.emit(resourceOperation(resourceSnapshot(11), 'mmdb', 'automatic-later', 'updating'));
  admission.resolve();
  await sync;
  assert.equal(h.store.items[0].operationId, 'automatic-later');
  assert.equal(h.store.items[0].phase, 'updating');
  assert.equal(h.store.notice.kind, 'single');
  assert.equal(h.store.notice.items[0].operationId, 'fast');
  assert.equal(h.store.notice.items[0].outcome, 'updated');
  const serial = h.store.noticeSerial;
  h.store.clearNotice();
  h.emit(resourceOperation(resourceSnapshot(12), 'mmdb', 'automatic-later', 'idle', 'unchanged'));
  h.emit(resourceOperation(resourceSnapshot(12), 'mmdb', 'duplicate', 'updating'));
  assert.equal(h.store.noticeSerial, serial);
  assert.equal(h.store.notice, undefined);
  assert.equal(h.store.items[0].phase, 'idle');
}));

test('批量保留各项首次终态，不混入自动任务，单批只有一次通知', async () => resourceStoreCase(async h => {
  await h.online();
  let admitted = resourceOperation(resourceSnapshot(2), 'mmdb', 'batch-mmdb', 'queued');
  admitted = resourceOperation(admitted, 'asn', 'batch-asn', 'queued');
  h.server.update = async (body, response) => {
    assert.deepEqual(body.ids, ['mmdb', 'asn']);
    return response(admitted, 202);
  };
  await h.store.sync(['mmdb', 'asn', 'asn']);
  assert.equal(h.store.notice, undefined);
  let partial = resourceOperation(resourceSnapshot(3), 'mmdb', 'batch-mmdb', 'idle', 'failed', 'geo_http_503');
  partial = resourceOperation(partial, 'asn', 'batch-asn');
  h.emit(partial);
  assert.equal(h.store.notice, undefined);
  let later = resourceOperation(resourceSnapshot(4), 'mmdb', 'auto-mmdb', 'idle', 'updated');
  later = resourceOperation(later, 'asn', 'batch-asn', 'idle', 'unchanged');
  h.emit(later);
  assert.equal(h.store.notice.kind, 'batch');
  assert.deepEqual(plain(h.store.notice.items).map(item => [item.id, item.operationId, item.outcome, item.error]),
    [['mmdb', 'batch-mmdb', 'failed', 'geo_http_503'], ['asn', 'batch-asn', 'unchanged', '']]);
  const serial = h.store.noticeSerial;
  h.store.clearNotice();
  h.emit({ ...later, revision: 5 });
  assert.equal(h.store.noticeSerial, serial);
  assert.equal(h.store.notice, undefined);
}));

test('真实ControllerSocket断线重连初始快照消除spinner，隐藏无重连与旧反馈', async () => resourceStoreCase(async h => {
  await h.online();
  const accepted = resourceOperation(resourceSnapshot(2), 'geosite', 'reconnect-op', 'queued');
  h.server.update = async (_body, response) => response(accepted, 202);
  await h.store.sync(['geosite']);
  assert.equal(h.store.items[3].phase, 'queued');
  h.sockets[0].disconnect();
  assert.equal(h.sockets[0].closed, true);
  assert.equal(h.clock.timers.size, 2);
  h.clock.advance(1999);
  assert.equal(h.sockets.length, 1);
  h.clock.advance(1);
  await untilResource(() => h.sockets.length === 2);
  h.emit(resourceOperation(resourceSnapshot(3), 'geosite', 'reconnect-op', 'idle', 'updated'));
  assert.equal(h.store.items[3].phase, 'idle');
  assert.equal(h.store.notice.items[0].operationId, 'reconnect-op');
  const serial = h.store.noticeSerial;
  h.store.setVisible(false);
  h.clock.advance(60000);
  assert.equal(h.sockets.length, 2);
  h.store.setVisible(true);
  await h.store.load(h.context);
  await untilResource(() => h.sockets.length === 3);
  h.emit(resourceOperation(resourceSnapshot(4), 'geosite', 'reconnect-op', 'idle', 'updated'));
  assert.equal(h.store.noticeSerial, serial);
  assert.equal(h.store.notice, undefined);
  assert.equal(h.requests.filter(request => request.route === '/arkclash/geo').length, 2);
}));

test('隐藏、boot变化与晚到受理丢弃旧批次，旧异步load不覆盖新设置或状态', async () => resourceStoreCase(async h => {
  await h.online();
  const gate = deferredResource();
  h.server.update = async (_body, response) => {
    await gate.promise;
    return response(resourceOperation(resourceSnapshot(2), 'mmdb', 'hidden-op', 'queued'), 202);
  };
  const sync = h.store.sync(['mmdb']);
  await untilResource(() => h.requests.some(request => request.route.endsWith('/update')));
  h.store.setVisible(false);
  gate.resolve();
  await sync;
  assert.equal(h.store.notice, undefined);
  h.server.snapshot = resourceSnapshot(1, 'default', 'boot-b');
  h.store.setConnection(true, 'boot-b');
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(h.store.canSync, true);
  const socket = h.sockets.at(-1);
  socket.emit(resourceOperation(resourceSnapshot(999), 'mmdb', 'hidden-op', 'idle', 'updated'));
  assert.equal(h.store.notice, undefined);
  assert.equal(h.store.items[0].operationId, '');
  const get = deferredResource();
  h.store.setVisible(false);
  h.server.getGate = get.promise;
  h.server.getStarted = false;
  h.store.setVisible(true);
  const oldLoad = h.store.load(h.context);
  await untilResource(() => h.server.getStarted);
  h.store.setVisible(false);
  h.server.getGate = undefined;
  h.server.snapshot = resourceSnapshot(1, 'default', 'boot-c');
  h.store.setConnection(true, 'boot-c');
  h.store.setVisible(true);
  await h.store.load(h.context);
  const revision = h.store.settings.revision;
  get.resolve();
  await oldLoad;
  assert.equal(h.store.settings.revision, revision);
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.notice, undefined);
}));

test('load等真实保存屏障，隐藏期间完成保存不写旧生命周期设置和notice', async () => resourceStoreCase(async h => {
  h.store.setVisible(true);
  await h.store.load(h.context);
  const gate = deferredResource();
  h.controls.writeGate = gate.promise;
  const save = h.store.saveUrl('geoip', 'https://barrier.example/geoip.dat');
  await untilResource(() => h.controls.writing);
  h.store.setVisible(false);
  h.store.setVisible(true);
  const load = h.store.load(h.context);
  assert.equal(h.store.settings.urls.geoip, h.geo.GEO_DEFAULT_URLS.geoip);
  gate.resolve();
  await Promise.all([save, load]);
  await untilResource(() => h.store.settings.urls.geoip === 'https://barrier.example/geoip.dat');
  assert.equal(h.store.saving, false);
  assert.equal(h.store.notice, undefined);
  assert.equal(h.requests.length, 0);
}));

test('多个本页批次共享operation时保留每批通知队列，隐藏清空所有未消费通知', async () => resourceStoreCase(async h => {
  await h.online();
  const single = resourceOperation(resourceSnapshot(2), 'mmdb', 'shared-op', 'queued');
  const all = resourceOperation(resourceOperation(resourceSnapshot(3), 'mmdb', 'shared-op', 'queued'),
    'asn', 'second-op', 'queued');
  let calls = 0;
  h.server.update = async (_body, response) => response(++calls === 1 ? single : all, 202);
  await h.store.sync(['mmdb']);
  await h.store.sync(['mmdb', 'asn']);
  const done = resourceOperation(resourceOperation(resourceSnapshot(4), 'mmdb', 'shared-op', 'idle', 'updated'),
    'asn', 'second-op', 'idle', 'unchanged');
  h.emit(done);
  assert.equal(h.store.notice.kind, 'single');
  const serial = h.store.noticeSerial;
  h.store.clearNotice();
  assert.equal(h.store.notice.kind, 'batch');
  assert.equal(h.store.noticeSerial, serial + 1);
  h.store.clearNotice();
  assert.equal(h.store.notice, undefined);
  h.emit({ ...done, revision: 5 });
  assert.equal(h.store.noticeSerial, serial + 1);
  h.store.setVisible(false);
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(h.store.notice, undefined);
}));

test('保存应用响应晚于新boot不改变新生命周期应用gate，也不回放保存通知', async () => resourceStoreCase(async h => {
  await h.online();
  const gate = deferredResource();
  h.server.applyGate = gate.promise;
  const save = h.store.saveAutoUpdate(true);
  await untilResource(() => h.server.applyStarted);
  const disk = await h.geo.readGeoSettings(h.dir);
  h.server.snapshot = resourceSnapshot(1, disk.revision, 'boot-b');
  h.server.applyGate = undefined;
  h.store.setConnection(true, 'boot-b');
  await h.store.load(h.context);
  gate.resolve();
  await save;
  await untilResource(() => !h.store.saving);
  assert.equal(h.store.settings.revision, disk.revision);
  assert.equal(h.store.settings.autoUpdate, true);
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.notice, undefined);
}));

test('旧load读出的设置与文件错误不能覆盖隐藏后新一代已加载状态', async () => resourceStoreCase(async h => {
  await h.online();
  h.store.setVisible(false);
  let old = await h.geo.readGeoSettings(h.dir);
  old.urls.mmdb = 'https://old.example/mmdb';
  await h.geo.saveGeoSettings(h.dir, old);
  const gate = deferredResource();
  let blocked = false;
  h.controls.readGate = async file => {
    if (!blocked && file.endsWith('geo-settings.json')) {
      blocked = true;
      await gate.promise;
    }
  };
  h.store.setVisible(true);
  const oldLoad = h.store.load(h.context);
  await untilResource(() => blocked);
  h.store.setVisible(false);
  h.controls.readGate = undefined;
  let latest = await h.geo.readGeoSettings(h.dir);
  latest.urls.mmdb = 'https://new.example/mmdb';
  latest = await h.geo.saveGeoSettings(h.dir, latest);
  h.server.snapshot = resourceSnapshot(2, latest.revision);
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(h.store.settings.urls.mmdb, 'https://new.example/mmdb');
  gate.resolve();
  await oldLoad;
  assert.equal(h.store.settings.revision, latest.revision);
  assert.equal(h.store.settings.urls.mmdb, 'https://new.example/mmdb');
  assert.equal(h.store.settingsError, '');
  assert.equal(h.store.canSync, true);
}));

test('损坏设置显式恢复只重置设置，保留数据库并重新开启在线应用gate', async () => resourceStoreCase(async h => {
  await fsp.writeFile(path.join(h.dir, 'geo-settings.json'), '{broken');
  await fsp.writeFile(path.join(h.dir, 'ASN.mmdb'), 'must-keep');
  h.store.setConnection(true, 'boot-a');
  h.store.setVisible(true);
  await h.store.load(h.context);
  assert.equal(h.store.settingsError, 'geo_invalid_settings');
  assert.equal(h.store.canSync, false);
  assert.equal(h.requests.filter(request => request.route.endsWith('/settings')).length, 0);
  await h.store.resetSettings();
  assert.equal(h.store.settingsError, '');
  assert.equal(h.store.settings.autoUpdate, true);
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.notice.kind, 'saved');
  assert.equal(await fsp.readFile(path.join(h.dir, 'ASN.mmdb'), 'utf8'), 'must-keep');
}));

test('同boot连接忙碌也停流，隐藏后受理失败被丢弃而不成为新页面错误', async () => resourceStoreCase(async h => {
  await h.online();
  const gate = deferredResource();
  h.server.update = async () => {
    await gate.promise;
    throw new Error('network https://private.example/?token=secret fixture-controller-secret');
  };
  const pending = h.store.sync(['asn']);
  await untilResource(() => h.requests.some(request => request.route.endsWith('/update')));
  h.store.setConnection(false, 'boot-a');
  assert.equal(h.sockets[0].closed, true);
  assert.equal(h.store.canSync, false);
  assert.equal(h.clock.timers.size, 1);
  h.store.setVisible(false);
  h.store.setConnection(true, 'boot-a');
  h.store.setVisible(true);
  await h.store.load(h.context);
  gate.resolve();
  await pending;
  assert.equal(h.store.error, '');
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.notice, undefined);
}));

test('推送已确认应用时晚到RPC失败不能撤销成功快照的同步gate', async () => resourceStoreCase(async h => {
  await h.online();
  const gate = deferredResource();
  h.server.applyGate = gate.promise;
  h.server.applyError = 'geo_timeout';
  const save = h.store.saveInterval(72);
  await untilResource(() => h.server.applyStarted);
  const disk = await h.geo.readGeoSettings(h.dir);
  h.emit(resourceSnapshot(7, disk.revision));
  gate.resolve();
  await save;
  assert.equal(h.store.pendingApply, false);
  assert.equal(h.store.canSync, true);
  assert.equal(h.store.notice.kind, 'saved');
  assert.equal(h.store.error, '');
}));

test('当前受理失败仅抛脱敏错误，不产生重复notice；推送错误只保留固定错误码', async () => resourceStoreCase(async h => {
  await h.online();
  h.server.update = async () => { throw new Error('https://private.example/?token=secret fixture-controller-secret'); };
  await assert.rejects(h.store.sync(['mmdb']), /^(Error: )?geo_download_failed$/);
  assert.equal(h.store.notice, undefined);
  h.emit(resourceOperation(resourceSnapshot(2), 'mmdb', 'automatic-failure', 'idle', 'failed',
    'https://private.example/?token=secret'));
  assert.equal(h.store.items[0].error, 'geo_download_failed');
  assert.equal(h.store.notice, undefined);
}));

function resourcePageActions(store) {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/features/resources/ResourcesPage.ets', import.meta.url), 'utf8');
  const methods = ['isCurrent', 'toast', 'saveAutomatic', 'syncResources', 'updating'].map(name => {
    const method = source.match(new RegExp(`^  private (?:async )?${name}\\([^\\n]*\\)[^\\n]*\\{[\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(method, `missing resource page action ${name}`);
    return method.replace(/^  private /, '  ');
  }).join('\n');
  const editor = fs.readFileSync(new URL('../entry/src/main/ets/features/resources/GeoResourceEditor.ets', import.meta.url), 'utf8');
  const errors = editor.match(/^export function geoErrorText\([^\n]*\)[^\n]*\{[\s\S]*?^}/m)?.[0];
  assert.ok(errors, 'missing real resource error mapping');
  const notices = [];
  const ui = { getPromptAction: () => ({ showToast: notice => notices.push(notice.message) }) };
  const compiled = ts.transpileModule(`${errors.replace(/^export /, '')}
class ResourcePageActions {
  active: boolean = true;
  generation: number = 1;
  automaticDraft: boolean | undefined = undefined;
  submitting: boolean = false;
  constructor(public store: ResourcesStore) {}
  getUIContext(): UIContext { return ui; }
${methods}
}
module.exports = ResourcePageActions;`, {
    fileName: 'ResourcePageActions.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(compiled, { module, exports: module.exports, ui, $r: key => key });
  return { page: new module.exports(store), notices };
}

test('正文自动更新草稿在真实保存失败后回滚，离线重试仍可保存', async () => resourceStoreCase(async h => {
  await h.geo.saveGeoSettings(h.dir, { ...h.geo.defaultGeoSettings(), autoUpdate: false });
  h.store.setVisible(true);
  await h.store.load(h.context);
  const { page, notices } = resourcePageActions(h.store);
  const gate = deferredResource();
  h.controls.writeGate = gate.promise;
  h.controls.fail = operation => operation === 'rename';
  const saving = page.saveAutomatic(true);
  await untilResource(() => h.controls.writing);
  assert.equal(page.automaticDraft, true);
  assert.equal(h.store.saving, true);
  assert.equal(h.store.settings.autoUpdate, false);
  gate.resolve();
  await saving;
  assert.equal(page.automaticDraft, undefined);
  assert.equal(page.automaticDraft ?? h.store.settings.autoUpdate, false);
  assert.equal((await h.geo.readGeoSettings(h.dir)).autoUpdate, false);
  assert.deepEqual(notices, ['app.string.geo_io']);
  h.controls.fail = undefined;
  h.controls.writeGate = undefined;
  await page.saveAutomatic(true);
  assert.equal(page.automaticDraft, undefined);
  assert.equal(h.store.settings.autoUpdate, true);
  assert.equal((await h.geo.readGeoSettings(h.dir)).autoUpdate, true);
  assert.equal(h.requests.length, 0);
}));

test('全部更新在受理和queued/updating期间均拒绝重复提交，实际完成后恢复', async () => resourceStoreCase(async h => {
  await h.online();
  const { page } = resourcePageActions(h.store);
  const ids = ['mmdb', 'asn', 'geoip', 'geosite'];
  const gate = deferredResource();
  let calls = 0;
  let accepted = resourceSnapshot(2);
  for (const id of ids) accepted = resourceOperation(accepted, id, `batch-${id}`, 'queued');
  h.server.update = async (_body, response) => {
    calls++;
    await gate.promise;
    return response(accepted, 202);
  };
  const pending = page.syncResources(ids);
  await untilResource(() => calls === 1);
  assert.equal(page.submitting, true);
  await page.syncResources(ids);
  assert.equal(calls, 1);
  gate.resolve();
  await pending;
  assert.equal(page.submitting, false);
  assert.equal(page.updating(), true);
  await page.syncResources(ids);
  assert.equal(calls, 1);
  let busy = resourceSnapshot(3);
  for (const id of ids) busy = resourceOperation(busy, id, `batch-${id}`, 'updating');
  h.emit(busy);
  await page.syncResources(ids);
  assert.equal(calls, 1);
  let done = resourceSnapshot(4);
  for (const id of ids) done = resourceOperation(done, id, `batch-${id}`, 'idle', 'updated');
  h.emit(done);
  assert.equal(page.updating(), false);
  accepted = resourceSnapshot(5);
  for (const id of ids) accepted = resourceOperation(accepted, id, `next-${id}`, 'queued');
  await page.syncResources(ids);
  assert.equal(calls, 2);
}));

test('旧页面受理失败不能清掉新页面提交状态或回放Toast', async () => resourceStoreCase(async h => {
  await h.online();
  const { page, notices } = resourcePageActions(h.store);
  const gate = deferredResource();
  let started = false;
  h.server.update = async () => { started = true; await gate.promise; throw new Error('fixture transport failure'); };
  const pending = page.syncResources(['mmdb']);
  await untilResource(() => started);
  page.generation++;
  page.active = false;
  page.submitting = true;
  gate.resolve();
  await pending;
  assert.equal(page.submitting, true);
  assert.deepEqual(notices, []);
}));
