// 仅用于本机 Node 回归。平台绑定使用本机文件系统，不覆盖产品文件，也不模拟内核应用或跨进程锁。
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
const compilerPath = process.env.ARKCLASH_TYPESCRIPT ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';
const ts = require(compilerPath);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const etsDir = path.resolve(scriptDir, '../entry/src/main/ets');
const featureDir = path.join(etsDir, 'features/profiles');
const modules = new Map();

function platformError(error) {
  if (error.code === 'ENOENT') { error.code = 13900002; }
  throw error;
}

const fileIo = {
  OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
    READ_WRITE: fs.constants.O_RDWR, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
  async access(file) { try { await fsp.access(file); return true; } catch (error) {
    if (error.code === 'ENOENT') { return false; } throw error;
  } },
  mkdir: (file, recursive) => fsp.mkdir(file, { recursive }),
  async readText(file) { try { return await fsp.readFile(file, 'utf8'); } catch (error) { platformError(error); } },
  readTextSync(file) { try { return fs.readFileSync(file, 'utf8'); } catch (error) { platformError(error); } },
  async unlink(file) { try { await fsp.unlink(file); } catch (error) { platformError(error); } },
  rename: (from, to) => fsp.rename(from, to),
  async copyFile(source, destination) {
    const bytes = await new Promise((resolve, reject) => fs.readFile(source, (error, data) => error ? reject(error) : resolve(data)));
    await new Promise((resolve, reject) => fs.writeFile(destination, bytes, (error) => error ? reject(error) : resolve()));
  },
  async open(file, flags) {
    const handle = await fsp.open(file, flags, 0o600);
    return { fd: handle.fd, handle, async lock() {}, tryLock() {} };
  },
  close: (file) => file.handle.close(),
  async write(fd, bytes) {
    return await new Promise((resolve, reject) => fs.write(fd, Buffer.from(bytes), (error, written) => {
      if (error) { reject(error); } else { resolve(written); }
    }));
  },
  async fsync(fd) {
    await new Promise((resolve, reject) => fs.fsync(fd, (error) => error ? reject(error) : resolve()));
  }
};

const kits = {
  '@kit.BasicServicesKit': {},
  '@kit.CoreFileKit': { fileIo },
  '@kit.NetworkKit': { http: {} },
  '@kit.ArkTS': { url: { URL }, util: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    Base64Helper: class { async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); } }
  } }
};

function load(file, selectedSource, overrides = {}) {
  const absolute = path.resolve(file);
  const key = `${absolute}:${selectedSource ?? ''}`;
  if (modules.has(key)) { return modules.get(key).exports; }
  const source = selectedSource ?? fs.readFileSync(absolute, 'utf8');
  const compiled = ts.transpileModule(source, {
    fileName: absolute.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const module = { exports: {} };
  modules.set(key, module);
  const localRequire = (name) => {
    if (kits[name]) { return kits[name]; }
    return load(path.resolve(path.dirname(absolute), `${name}.ets`));
  };
  vm.runInNewContext(compiled, { module, exports: module.exports, require: localRequire, console, URL,
    setTimeout, clearTimeout, TextEncoder, TextDecoder, Buffer, ...overrides }, { filename: absolute });
  return module.exports;
}

function exportedFunction(file, name, prelude) {
  const text = fs.readFileSync(file, 'utf8');
  const ast = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declaration = ast.statements.find((node) => ts.isFunctionDeclaration(node) && node.name?.text === name);
  assert.ok(declaration, `Missing public function ${name}`);
  return load(file, `${prelude}\n${declaration.getText(ast)}`)[name];
}

const store = load(path.join(etsDir, 'shared/profiles/Store.ets'));
const download = load(path.join(etsDir, 'shared/profiles/Download.ets'));
const parseLinks = exportedFunction(path.join(featureDir, 'ProfileActions.ets'), 'parseProfileLinks',
  "import { validSubscriptionUrl } from '../../shared/profiles/Download';");
const nextDue = exportedFunction(path.join(etsDir, 'shared/profiles/Updater.ets'), 'nextDue',
  "import { intervalMinutes } from './Store';\nconst MINUTE_MS = 60000;");
const { runProfileBatch } = load(path.join(featureDir, 'ProfileBatch.ets'));
const { profileResultLines } = load(path.join(featureDir, 'ProfileResultLines.ets'));

async function sandbox(run) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'arkclash-profile-case-'));
  try { await run(dir); } finally { await fsp.rm(dir, { recursive: true, force: true }); }
}

test('missing selections return an empty map; corrupt selections are preserved and rejected', async () => {
  await sandbox(async (dir) => {
    assert.deepEqual(JSON.parse(JSON.stringify(await store.readSelected(dir, 'p1'))), {});
    await store.ensureProfilesDir(dir);
    const file = store.selectedPath(dir, 'p1');
    await fsp.writeFile(file, '{broken', 'utf8');
    await assert.rejects(store.readSelected(dir, 'p1'), /corrupt/);
    assert.equal(await fsp.readFile(file, 'utf8'), '{broken');
    await fsp.writeFile(file, '{"group":12}', 'utf8');
    await assert.rejects(store.readSelected(dir, 'p1'), /corrupt/);
    assert.equal(await fsp.readFile(file, 'utf8'), '{"group":12}');
  });
});

test('selection writes stay atomic and preserve subscription and unknown manifest fields', async () => {
  await sandbox(async (dir) => {
    const list = { version: 1, current: 'p1', profiles: [{ id: 'p1', name: 'local.yaml', nameEdited: false,
      subscription: '', futureField: 'keep' }], subscriptions: [], futureManifest: { preserve: true } };
    await store.writeList(dir, list);
    await Promise.all(Array.from({ length: 12 }, (_, index) => store.writeSelected(dir, 'p1', { group: `node-${index}` })));
    const selected = await store.readSelected(dir, 'p1');
    assert.match(selected.group, /^node-\d+$/);
    const saved = await store.readListAsync(dir);
    assert.equal(saved.profiles[0].futureField, 'keep');
    assert.equal(saved.futureManifest.preserve, true);
    assert.equal(saved.current, 'p1');
    assert.deepEqual((await fsp.readdir(store.profilesDir(dir))).filter((name) => name.endsWith('.tmp')), []);
    await assert.rejects(store.writeSelected(dir, 'deleted', { group: 'node' }), /not_found/);
  });
});

test('corrupt manifests never become an empty library', async () => {
  await sandbox(async (dir) => {
    await store.ensureProfilesDir(dir);
    await fsp.writeFile(store.listPath(dir), '{"version":1,"profiles":[]}', 'utf8');
    await assert.rejects(store.readListAsync(dir), /corrupt/);
    assert.equal(await fsp.readFile(store.listPath(dir), 'utf8'), '{"version":1,"profiles":[]}');
  });
});

test('subscription headers preserve file extensions, normalize keys and clear missing usage', () => {
  const info = download.infoFromHeaders({ 'Content-Disposition': "attachment; filename=old.yaml; filename*=UTF-8''new.yaml",
    'Subscription-Userinfo': 'Upload=10.8; DOWNLOAD=20;total=100;expire=123.9' });
  assert.equal(info.name, 'new.yaml');
  assert.deepEqual(JSON.parse(JSON.stringify(info.usage)), { upload: 10, download: 20, total: 100, expire: 123 });
  assert.deepEqual(JSON.parse(JSON.stringify(download.infoFromHeaders({}).usage)), { upload: 0, download: 0, total: 0, expire: 0 });
});

test('URL grammar, credentials and batch line diagnostics use the public import helpers', async () => {
  assert.equal(download.validSubscriptionUrl('ftp://example.invalid/source'), true);
  assert.equal(download.validSubscriptionUrl('ss://example.invalid'), false);
  assert.equal(download.validSubscriptionUrl('https://'), false);
  const credentialUrl = ['https://', 'user', ':', 'secret', '@', 'example.invalid/config'].join('');
  const address = await download.prepareDownloadAddress(credentialUrl);
  assert.equal(address.address, 'https://example.invalid/config');
  assert.equal(address.headers.Authorization, `Basic ${Buffer.from('user:secret').toString('base64')}`);
  const parsed = parseLinks('- "https://a.invalid/config",\nhttps://b.invalid/x https://a.invalid/config\nbroken', []);
  assert.equal(parsed.entries.length, 2);
  assert.equal(parsed.skipped, 1);
  assert.equal(parsed.errors[0], 3);
});

test('1440-minute defaults, minute intervals and failures keep the successful timestamp as the due basis', () => {
  assert.equal(store.DEFAULT_INTERVAL_MINUTES, 1440);
  assert.equal(nextDue({ autoUpdate: true, intervalHours: 24 }, { updatedAt: 1000, failures: 5, failedAt: 999999 }), 86401000);
  assert.equal(nextDue({ autoUpdate: true, intervalHours: 24, intervalMinutes: 1 }, { updatedAt: 1000, failures: 0 }), 61000);
  assert.equal(nextDue({ autoUpdate: false, intervalHours: 24 }, { updatedAt: 0, failures: 0 }), 0);
  assert.equal(nextDue({ autoUpdate: true, intervalHours: 24 }, { updatedAt: 0, failures: 0 }), 1);
});

test('manual batches use at most four tasks and retain partial successes and failures', async () => {
  let active = 0;
  let maximum = 0;
  const jobs = Array.from({ length: 9 }, (_, index) => ({ id: `${index}`, name: `profile-${index}`,
    async run() { active++; maximum = Math.max(maximum, active); await new Promise((resolve) => setImmediate(resolve));
      active--; return index === 3 || index === 7 ? 'network' : undefined; } }));
  const result = await runProfileBatch(jobs, 2, () => {});
  assert.equal(maximum, 4);
  assert.equal(result.succeeded, 7);
  assert.equal(result.skipped, 2);
  assert.equal(result.failures.length, 2);
});

test('failure result rows retain duplicate invalid links and a separate description for each error group', () => {
  const failures = [
    { id: '', name: '', error: 'url_invalid', line: 7 },
    { id: 'saved', name: 'Saved profile', error: 'network' },
    { id: '', name: '', error: 'url_invalid', line: 7 }
  ];
  const rows = profileResultLines(failures);
  assert.deepEqual(Array.from(rows, (row) => [row.description, row.error, row.name, row.line, row.first, row.last]), [
    [false, 'url_invalid', '', 7, true, false],
    [false, 'url_invalid', '', 7, false, true],
    [true, 'url_invalid', '', undefined, false, false],
    [false, 'network', 'Saved profile', undefined, true, true],
    [true, 'network', '', undefined, false, false]
  ]);
  const keys = Array.from(rows, (row) => row.key);
  assert.equal(new Set(keys).size, rows.length);
  const regrouped = profileResultLines([failures[1], failures[0], failures[2]]);
  assert.deepEqual(Array.from(regrouped.filter((row) => row.error === 'url_invalid'), (row) => row.key), keys.slice(0, 3));
  assert.deepEqual(Array.from(regrouped.filter((row) => row.error === 'network'), (row) => row.key), keys.slice(3));
  assert.equal(profileResultLines([]).length, 0);
});

test('large same-error results expose every failure as one row with stable unique keys', () => {
  const failures = Array.from({ length: 4096 }, (_, index) => ({
    id: '', name: '', error: 'url_invalid', line: Math.floor(index / 2) + 1
  }));
  const rows = profileResultLines(failures);
  assert.equal(rows.length, 4097);
  for (let index = 0; index < failures.length; index++) {
    assert.equal(rows[index].description, false);
    assert.equal(rows[index].line, failures[index].line);
    assert.equal(rows[index].name, failures[index].name);
    assert.equal(rows[index].first, index === 0);
    assert.equal(rows[index].last, index === failures.length - 1);
  }
  assert.equal(rows.at(-1).description, true);
  assert.equal(rows.at(-1).error, 'url_invalid');
  const keys = Array.from(rows, (row) => row.key);
  assert.equal(new Set(keys).size, 4097);
  assert.deepEqual(Array.from(profileResultLines(failures.map((failure) => ({ ...failure }))), (row) => row.key), keys);
  const extended = profileResultLines([{ id: 'new', name: 'New failure', error: 'url_invalid', line: 0 }, ...failures]);
  assert.deepEqual(Array.from(extended.slice(1), (row) => row.key), keys);
  const ambiguous = profileResultLines([
    { id: 'a:1', name: 'b', error: 'network', line: 2 },
    { id: 'a', name: '2:b', error: 'network', line: 1 }
  ]);
  assert.notEqual(ambiguous[0].key, ambiguous[1].key);
});

const storeImport = "import { checkProfileCommit, findProfile, listPath, readListAsync, readOptionalText, writeList, writeProfileText, withProfileStorage, removeProfileFile, yamlPath, summaryPath, statePath, selectedPath } from '../../shared/profiles/Store';";
const removeSavedProfile = exportedFunction(path.join(featureDir, 'ProfileActions.ets'), 'removeSavedProfile', storeImport);
const saveProfileOrder = exportedFunction(path.join(featureDir, 'ProfileActions.ets'), 'saveProfileOrder', storeImport);

test('deleting a profile clears its selections and subscription state without touching the next profile', async () => {
  await sandbox(async (dir) => {
    await store.writeList(dir, { version: 1, current: 'p1', profiles: [
      { id: 'p1', name: 'remote', nameEdited: false, subscription: 's1' },
      { id: 'p2', name: 'local.yaml', nameEdited: false, subscription: '' }
    ], subscriptions: [{ id: 's1', url: 'https://example.invalid/source', autoUpdate: true, intervalHours: 24 }] });
    await store.writeProfileText(store.yamlPath(dir, 'p1'), 'source');
    await store.writeProfileText(store.summaryPath(dir, 'p1'), '{}');
    await store.writeState(dir, 's1', { updatedAt: 1000, failures: 0 });
    await store.writeSelected(dir, 'p1', { group: 'first' });
    await store.writeSelected(dir, 'p2', { group: 'second' });
    await removeSavedProfile(dir, 'p1');
    const saved = await store.readListAsync(dir);
    assert.equal(saved.current, 'p2');
    assert.equal(saved.profiles.length, 1);
    assert.equal(saved.subscriptions.length, 0);
    await assert.rejects(fsp.access(store.selectedPath(dir, 'p1')));
    await assert.rejects(fsp.access(store.statePath(dir, 's1')));
    assert.equal((await store.readSelected(dir, 'p2')).group, 'second');
  });
});

test('saving an order appends profiles created while the sorting panel was open', async () => {
  await sandbox(async (dir) => {
    await store.writeList(dir, { version: 1, current: 'p2', subscriptions: [], profiles:
      ['p1', 'p2', 'p3'].map((id) => ({ id, name: id, nameEdited: false, subscription: '' })) });
    await saveProfileOrder(dir, ['p2', 'p1']);
    const saved = await store.readListAsync(dir);
    assert.equal(saved.profiles.map((profile) => profile.id).join(','), 'p2,p1,p3');
    assert.equal(saved.current, 'p2');
  });
});

test('startup checks immediately, runs serially, and retries failures after a 20-minute round', { timeout: 3000 }, async () => {
  await sandbox(async (dir) => {
    const file = path.join(etsDir, 'shared/profiles/Updater.ets');
    const text = fs.readFileSync(file, 'utf8');
    const ast = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const declaration = ast.statements.find((node) => ts.isClassDeclaration(node) && node.name?.text === 'UpdateScheduler');
    assert.ok(declaration);
    const scheduleDeclarations = ast.statements.filter((node) =>
      (ts.isVariableStatement(node) && node.declarationList.declarations.some((entry) =>
        ['MINUTE_MS', 'CHECK_INTERVAL_MS'].includes(entry.name.getText(ast)))) ||
      (ts.isFunctionDeclaration(node) && node.name?.text === 'nextDue'))
      .map((node) => node.getText(ast)).join('\n');
    let now = 10000;
    let finishRound;
    const timers = [];
    const prelude = "import { checkProfileCommit, readListAsync, readStateAsync, findSubscription, intervalMinutes } from './Store';\nimport { ProfileError } from './Errors';";
    const Scheduler = load(file, `${prelude}\n${scheduleDeclarations}\n${declaration.getText(ast)}`, {
      Date: { now: () => now },
      setTimeout(callback, delay) { timers.push({ callback, delay }); finishRound?.(); return timers.length; },
      clearTimeout() {}
    }).UpdateScheduler;
    await store.writeList(dir, { version: 1, current: 'p1',
      profiles: ['p1', 'p2', 'p3'].map((id, index) => ({ id, name: id, nameEdited: false, subscription: `s${index + 1}` })),
      subscriptions: ['s1', 's2', 's3'].map((id) => ({ id, url: `https://${id}.invalid/config`, autoUpdate: id !== 's2', intervalHours: 24 })) });
    const calls = [];
    let active = 0;
    let maximum = 0;
    // 更新动作替换为可控失败；到期筛选、轮次与定时仍执行真实 UpdateScheduler。
    class FailingScheduler extends Scheduler {
      async update(subscription) {
        active++; maximum = Math.max(maximum, active); calls.push(subscription);
        const state = await store.readStateAsync(dir, subscription);
        state.failures++; state.failedAt = now;
        await store.writeState(dir, subscription, state);
        active--;
        return { subscription, ok: false, error: 'network', state };
      }
    }
    const scheduler = new FailingScheduler({ filesDir: dir }, () => {});
    const firstRound = new Promise((resolve) => { finishRound = resolve; });
    scheduler.start(); scheduler.start();
    await firstRound;
    assert.equal(calls.join(','), 's1,s3');
    assert.equal(maximum, 1);
    assert.equal(timers.length, 1);
    assert.equal(timers[0].delay, 1200000);
    now += 1200000;
    const secondRound = new Promise((resolve) => { finishRound = resolve; });
    timers[0].callback();
    await secondRound;
    assert.equal(calls.join(','), 's1,s3,s1,s3');
    assert.equal((await store.readStateAsync(dir, 's1')).updatedAt, 0);
    assert.equal(timers[1].delay, 1200000);
    const generation = scheduler.operationGeneration();
    scheduler.stop(true);
    assert.equal(scheduler.acceptsGeneration(generation), false);
  });
});

const flushProfileCallbacks = async () => { for (let index = 0; index < 24; index++) { await Promise.resolve(); } };

async function waitForProfileFixture(predicate) {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    assert.ok(Date.now() < deadline, 'Profile consumer did not reach the expected public boundary');
    await new Promise((resolve) => setImmediate(resolve));
  }
}

function profileRuntime(profile, configRevision, bootId = 'profile.boot.a', revision = configRevision) {
  return { profile, running: true, intent: 'started', forward: 'running', sessionMode: 'tun',
    tunAttached: true, listenersOpen: false, startedAt: 1, bootId, configRevision, revision,
    version: 'profile.fixture', mode: 'rule' };
}

async function actualProfileConsumer(filesDir,
  { subscription = false, autoUpdate = false, initialHost = 'stopped', legacy = false } = {}) {
  const requests = [];
  const sockets = [];
  const moduleCache = new Map();
  const timers = new Map();
  let nextTimer = 0;
  let pendingIO = 0;
  let selectedUris = [];
  let saveUris = [];
  let ioHold;
  const connectionInput = { connected: initialHost === 'running', busy: false, bootId: 'profile.boot.a', error: '',
    recheckFailure: initialHost === 'unknown' ? new Error('unconfirmed host') : undefined, rechecks: 0,
    async recheck() { this.rechecks++; if (this.recheckFailure) { throw this.recheckFailure; } return this.connected; } };
  const io = {};
  for (const key of Object.keys(fileIo)) {
    const original = fileIo[key];
    if (typeof original !== 'function' || key === 'readTextSync') { io[key] = original; continue; }
    io[key] = async (...args) => {
      pendingIO++;
      const hold = ioHold?.method === key && ioHold.predicate(...args) ? ioHold : undefined;
      if (hold) { ioHold = undefined; }
      try {
        if (hold && !hold.after) { hold.enter(); await hold.released; }
        const result = await original(...args);
        if (hold?.after) { hold.enter(); await hold.released; }
        return result;
      } finally { pendingIO--; }
    };
  }
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST', PATCH: 'PATCH' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
    createHttp() {
      const handle = { destroyed: false, destroy() { this.destroyed = true; },
        request(address, options) {
          return new Promise((resolve, reject) => {
            const request = { address, options, path: new URL(address).pathname, handle, taken: false, settled: false,
              respond(payload) { this.settled = true; resolve({ responseCode: 200, result: payload === undefined ? '' : JSON.stringify(payload) }); },
              respondSource(text, headers = {}) {
                this.settled = true;
                const bytes = new TextEncoder().encode(text);
                resolve({ responseCode: 200, result: bytes.buffer, header: headers });
              },
              fail(error) { this.settled = true; reject(error); } };
            requests.push(request);
          });
        } };
      return handle;
    }
  };
  const webSocket = { createWebSocket() {
    const handlers = new Map();
    const wire = { active: false,
      on(name, handler) { handlers.set(name, handler); }, off(name) { handlers.delete(name); },
      async connect() { this.active = true; }, async close() { this.active = false; },
      emit(payload) { handlers.get('message')?.(undefined, JSON.stringify(payload)); } };
    sockets.push(wire);
    return wire;
  } };
  const realm = vm.createContext({ console, Date, Promise, Error, JSON, Number, Math, Set, Map, Array, Object,
    String, URL, Uint8Array, ArrayBuffer,
    setTimeout(callback, milliseconds) { timers.set(++nextTimer, { callback, milliseconds }); return nextTimer; },
    clearTimeout(id) { timers.delete(id); } });
  function loadActual(file) {
    const absolute = path.resolve(file);
    if (moduleCache.has(absolute)) { return moduleCache.get(absolute).exports; }
    const record = { exports: {} }; moduleCache.set(absolute, record);
    const source = fs.readFileSync(absolute, 'utf8').replace(/^\s*@ObservedV2\s*$/gm, '')
      .replace(/@Trace\s+/g, '').replace(/^\s*@Concurrent\s*$/gm, '');
    const code = ts.transpileModule(source, {
      fileName: `${absolute}.ts`, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
    }).outputText;
    const scopedRequire = (name) => {
      if (name === '@kit.AbilityKit' || name === '@kit.BasicServicesKit') { return {}; }
      if (name === '@kit.ArkData') { return { preferences: {
        async getPreferences() { return { async get(_key, fallback) { return fallback; } }; }
      } }; }
      if (name === '@kit.CoreFileKit') { return { fileIo: io, picker: {
        DocumentSelectOptions: class {}, DocumentSaveOptions: class {},
        DocumentViewPicker: class {
          async select() { const result = selectedUris; selectedUris = []; return result; }
          async save() { const result = saveUris; saveUris = []; return result; }
        }
      }, hash: {
        async hash(file, algorithm) { return require('node:crypto').createHash(algorithm).update(await fsp.readFile(file)).digest('hex').toUpperCase(); }
      } }; }
      if (name === '@kit.ArkTS') { return { ...kits[name], taskpool: { async execute(action, ...args) { return action(...args); } } }; }
      if (name === '@kit.NetworkKit') { return { http, webSocket }; }
      if (name === 'yaml') { return { parse(...args) {
        return require(path.resolve(scriptDir, '../entry/oh_modules/yaml/dist/index.js')).parse(...args);
      } }; }
      const target = path.resolve(path.dirname(absolute), `${name}.ets`);
      if (target === path.join(etsDir, 'client/Connection.ets')) { return { connection: connectionInput }; }
      if (target === path.join(etsDir, 'shared/Runtime.ets')) {
        return { CONTROLLER_ADDRESS: '127.0.0.1:19090', readRuntime: async () => ({ secret: 'profile.fixture.token' }) };
      }
      return loadActual(target);
    };
    new vm.Script(`(function(require,module,exports){${code}\n})`, { filename: absolute })
      .runInContext(realm)(scopedRequire, record, record.exports);
    return record.exports;
  }
  const actualStore = loadActual(path.join(etsDir, 'shared/profiles/Store.ets'));
  if (legacy) {
    await actualStore.ensureProfilesDir(filesDir);
    await actualStore.writeProfileText(path.join(store.profilesDir(filesDir), 'default.yaml'), 'proxies: []\n');
  } else {
    await actualStore.writeList(filesDir, { version: 1, current: 'p1',
      subscriptions: subscription ? [{ id: 's1', url: 'https://subscription.invalid/source', autoUpdate,
        intervalHours: 24, intervalMinutes: 1440, revision: 'subscription.1' }] : [], profiles:
      ['p1', 'p2', 'p3'].map((id) => ({ id, name: id, nameEdited: false, subscription: subscription && id === 'p1' ? 's1' : '' })) });
    for (const id of ['p1', 'p2', 'p3']) {
      await actualStore.writeProfileText(actualStore.yamlPath(filesDir, id), 'proxies: []\n');
      await actualStore.writeProfileText(actualStore.summaryPath(filesDir, id), JSON.stringify({ groups: [], proxies: 0, revision: `source.${id}` }));
    }
  }
  const { ProfileStore } = loadActual(path.join(featureDir, 'Profiles.ets'));
  const view = new ProfileStore();
  view.load({ filesDir });
  await waitForProfileFixture(() => view.loaded);
  assert.equal(view.loadError, '');
  async function take(route) {
    await waitForProfileFixture(() => requests.some((request) => !request.taken && request.path === route));
    const request = requests.find((entry) => !entry.taken && entry.path === route);
    request.taken = true;
    return request;
  }
  return { view, connection: connectionInput, requests, take, store: actualStore,
    pick(uri) { selectedUris = [uri]; }, saveTo(uri) { saveUris = [uri]; },
    draft(id) { return new (loadActual(path.join(featureDir, 'ProfileDraft.ets')).ProfileDraft)(view.find(id)); },
    async idle() {
      await flushProfileCallbacks();
      for (let index = 0; index < 3; index++) {
        await waitForProfileFixture(() => pendingIO === 0);
        await new Promise((resolve) => setImmediate(resolve));
      }
    },
    holdIO(method, predicate, after = false) {
      assert.equal(ioHold, undefined);
      let enter; let release;
      const entered = new Promise((resolve) => { enter = resolve; });
      const released = new Promise((resolve) => { release = resolve; });
      ioHold = { method, predicate, after, enter, released };
      return { entered, release };
    },
    unknown() {
      connectionInput.connected = false;
      connectionInput.recheckFailure = new Error('unconfirmed host');
      view.setConnected(false, false);
    },
    stopped() {
      connectionInput.connected = false;
      connectionInput.recheckFailure = undefined;
      view.setConnected(false, true);
    },
    emit(payload) {
      const wire = sockets.filter((socket) => socket.active).at(-1);
      assert.ok(wire, 'The real ProfileEvents consumer must subscribe before receiving runtime events');
      wire.emit(payload);
    },
    async connect(status) {
      connectionInput.recheckFailure = undefined;
      connectionInput.connected = true;
      connectionInput.bootId = status.bootId;
      view.setConnected(true);
      const request = await take('/arkclash/status');
      request.respond(status);
      await flushProfileCallbacks();
    },
    async close() {
      view.setForeground(false);
      for (const request of requests) {
        if (!request.settled && !request.address.startsWith('http://127.0.0.1:19090/')) {
          request.fail(new Error('fixture closed')); continue;
        }
        if (!request.settled) { request.respond(profileRuntime('p1', 1, connectionInput.bootId)); }
      }
      await flushProfileCallbacks();
      for (let index = 0; index < 3; index++) {
        await waitForProfileFixture(() => pendingIO === 0);
        await new Promise((resolve) => setImmediate(resolve));
      }
      timers.clear();
    }
  };
}

test('real ProfileStore rejects the older status reply after two overlapping reload notifications', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      fixture.connection.connected = true;
      fixture.view.setConnected(true);
      const older = await fixture.take('/arkclash/status');
      fixture.emit({ type: 'reloaded', profile: 'p3' });
      const newer = await fixture.take('/arkclash/status');
      newer.respond(profileRuntime('p2', 2));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p2');
      older.respond(profileRuntime('p1', 1));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p2');
      assert.equal(fixture.view.active().id, 'p2');
      assert.equal(fixture.view.current, 'p1');
    } finally { await fixture.close(); }
  });
});

test('real runtime events invalidate pending profile reads and lower config revisions cannot replace the accepted profile', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      await fixture.connect(profileRuntime('p1', 1));
      fixture.emit({ type: 'reloaded', profile: 'p2' });
      const pending = await fixture.take('/arkclash/status');
      fixture.emit({ type: 'runtime', status: profileRuntime('p3', 3) });
      assert.equal(fixture.view.running, 'p3');
      pending.respond(profileRuntime('p2', 2));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p3');
      fixture.emit({ type: 'reloaded', profile: 'p2' });
      const latestButOldConfig = await fixture.take('/arkclash/status');
      latestButOldConfig.respond(profileRuntime('p2', 2, 'profile.boot.a', 99));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p3');
      fixture.emit({ type: 'reloaded', profile: 'p1' });
      const staleFailure = await fixture.take('/arkclash/status');
      fixture.emit({ type: 'runtime', status: profileRuntime('p2', 4) });
      assert.equal(fixture.view.running, 'p2');
      staleFailure.fail(new Error('late controller failure'));
      await flushProfileCallbacks();
      assert.equal(fixture.view.applyError, '');
      fixture.emit({ type: 'runtime', status: profileRuntime('p1', 1, 'profile.boot.a', 100) });
      assert.equal(fixture.view.running, 'p2');
      fixture.emit({ type: 'reloaded', profile: 'p3' });
      const afterDuplicate = await fixture.take('/arkclash/status');
      fixture.emit({ type: 'runtime', status: profileRuntime('p2', 4) });
      afterDuplicate.respond(profileRuntime('p3', 5));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p3');
    } finally { await fixture.close(); }
  });
});

test('real ProfileStore accepts the new boot revision reset and rejects old-boot events and status replies', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      await fixture.connect(profileRuntime('p1', 8, 'profile.boot.a', 20));
      fixture.emit({ type: 'reloaded', profile: 'p1' });
      const oldBootRead = await fixture.take('/arkclash/status');
      fixture.emit({ type: 'runtime', status: profileRuntime('p2', 1, 'profile.boot.b') });
      assert.equal(fixture.view.running, 'p2');
      oldBootRead.respond(profileRuntime('p1', 100, 'profile.boot.a', 100));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p2');
      fixture.connection.bootId = 'profile.boot.b';
      fixture.emit({ type: 'reloaded', profile: 'p1' });
      const latestRead = await fixture.take('/arkclash/status');
      latestRead.respond(profileRuntime('p1', 200, 'profile.boot.a', 200));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p2');
      fixture.emit({ type: 'runtime', status: profileRuntime('p3', 2, 'profile.boot.b') });
      fixture.emit({ type: 'runtime', status: profileRuntime('p1', 999, 'profile.boot.a', 999) });
      assert.equal(fixture.view.running, 'p3');
      assert.equal(fixture.view.active().id, 'p3');
    } finally { await fixture.close(); }
  });
});

test('real profile reads are replaced when Connection observes a new core boot while the request is pending', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      await fixture.connect(profileRuntime('p1', 1));
      fixture.emit({ type: 'reloaded', profile: 'p1' });
      const previousBoot = await fixture.take('/arkclash/status');
      fixture.connection.bootId = 'profile.boot.b';
      previousBoot.respond(profileRuntime('p3', 2));
      const currentBoot = await fixture.take('/arkclash/status');
      assert.equal(fixture.view.running, 'p1');
      currentBoot.respond(profileRuntime('p2', 1, 'profile.boot.b'));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p2');
    } finally { await fixture.close(); }
  });
});

test('real selection keeps the persisted target separate and takes the running profile only from controller status', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      await fixture.connect(profileRuntime('p1', 1));
      fixture.emit({ type: 'reloaded', profile: 'p1' });
      const stale = await fixture.take('/arkclash/status');
      const selecting = fixture.view.select('p2');
      const reload = await fixture.take('/arkclash/reload');
      assert.equal(await fixture.view.select('p3'), 'busy');
      assert.equal(fixture.view.pending, 'p2');
      assert.equal(JSON.parse(reload.options.extraData).profile, 'p2');
      reload.respond({});
      const confirmation = await fixture.take('/arkclash/status');
      assert.equal(fixture.view.current, 'p2');
      assert.equal(fixture.view.running, 'p1');
      stale.respond(profileRuntime('p1', 2));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p1');
      confirmation.respond(profileRuntime('p3', 4));
      await selecting;
      assert.equal(fixture.view.running, 'p3');
      assert.equal(fixture.view.active().id, 'p3');
      assert.equal(fixture.view.current, 'p2');
      assert.equal((await store.readListAsync(dir)).current, 'p2');
    } finally { await fixture.close(); }
  });
});

test('real foreground handoff rejects the old query and keeps the same-boot runtime watermark on reconnect', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      await fixture.connect(profileRuntime('p1', 5));
      fixture.emit({ type: 'reloaded', profile: 'p2' });
      const beforeBackground = await fixture.take('/arkclash/status');
      fixture.view.setForeground(false);
      beforeBackground.respond(profileRuntime('p2', 6));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p1');
      fixture.view.setForeground(true);
      const resumed = await fixture.take('/arkclash/status');
      resumed.respond(profileRuntime('p3', 7));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, 'p3');
      fixture.view.setConnected(false);
      fixture.view.setConnected(true);
      const reconnected = await fixture.take('/arkclash/status');
      reconnected.respond(profileRuntime('p1', 5));
      await flushProfileCallbacks();
      assert.equal(fixture.view.running, '');
      fixture.emit({ type: 'runtime', status: profileRuntime('p3', 7) });
      assert.equal(fixture.view.running, 'p3');
    } finally { await fixture.close(); }
  });
});

async function profileBusinessFiles(filesDir) {
  const files = {};
  for (const name of (await fsp.readdir(store.profilesDir(filesDir))).sort()) {
    if (name === 'list.json' || /\.(yaml|summary\.json|state\.json|selected\.json)$/.test(name)) {
      files[name] = await fsp.readFile(path.join(store.profilesDir(filesDir), name), 'utf8');
    }
  }
  return files;
}

test('real ProfileStore keeps cached reads, source drafts and exports available while unknown blocks every business mutation',
  { timeout: 15000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { subscription: true, initialHost: 'unknown' });
      try {
        await fixture.idle();
        const before = await profileBusinessFiles(dir);
        const imported = path.join(dir, 'import.yaml');
        await fsp.writeFile(imported, 'proxies: []\nmode: direct\n');
        const draft = fixture.draft('p2');
        draft.name = 'Unsaved name';
        draft.content = 'proxies: []\nmode: global\n';
        const edit = { name: draft.name, url: '', autoUpdate: false, intervalMinutes: 1440, content: draft.content };
        const changes = [
          ['select', () => fixture.view.select('p2')],
          ['metadata', () => fixture.view.edit('p2', { ...edit, content: undefined })],
          ['source', () => fixture.view.edit('p2', edit)],
          ['order', () => fixture.view.reorder(['p3', 'p2', 'p1'])],
          ['delete', () => fixture.view.remove('p3')],
          ['download', () => fixture.view.update('p1')],
          ['add', () => fixture.view.addSubscription('https://new.invalid/source')],
          ['file import', () => { fixture.pick(imported); return fixture.view.importLocal(); }]
        ];
        for (const [name, mutate] of changes) {
          const rechecks = fixture.connection.rechecks;
          assert.equal(await mutate(), 'host_unknown', name);
          assert.ok(fixture.connection.rechecks > rechecks, `${name} must await the real route recheck`);
          await fixture.idle();
          assert.deepEqual(await profileBusinessFiles(dir), before, name);
        }
        const links = await fixture.view.importLinks('https://new.invalid/source');
        assert.equal(links.succeeded, 0);
        assert.equal(links.failures[0].error, 'host_unknown');
        const batch = await fixture.view.updateAll();
        assert.equal(batch.succeeded, 0);
        assert.equal(batch.failures[0].error, 'host_unknown');
        assert.equal(fixture.requests.length, 0);
        assert.equal(fixture.view.ready, true);
        assert.equal(await fixture.view.source('p2'), 'proxies: []\n');
        assert.equal(await fixture.view.validateSource(draft.content), undefined);
        fixture.pick(imported);
        assert.equal(await fixture.view.pickSource(), 'proxies: []\nmode: direct\n');
        assert.equal(draft.dirty(), true);
        assert.equal(draft.content, edit.content);
        assert.equal(draft.name, edit.name);
        const exported = path.join(dir, 'export.yaml');
        await fsp.writeFile(exported, '');
        fixture.saveTo(exported);
        assert.equal(await fixture.view.export('p2'), undefined);
        assert.equal(await fsp.readFile(exported, 'utf8'), 'proxies: []\n');
        assert.deepEqual(await profileBusinessFiles(dir), before);
        fixture.stopped();
        assert.equal(await fixture.view.select('p2'), undefined);
        assert.equal(await fixture.view.edit('p2', edit), undefined);
        assert.equal(await fixture.view.reorder(['p3', 'p2', 'p1']), undefined);
        assert.equal(await fixture.view.remove('p3'), undefined);
        const saved = await fixture.store.readListAsync(dir);
        assert.equal(saved.current, 'p2');
        assert.equal(saved.profiles.find((profile) => profile.id === 'p2').name, 'Unsaved name');
        assert.equal(saved.profiles.some((profile) => profile.id === 'p3'), false);
        assert.equal(await fsp.readFile(store.yamlPath(dir, 'p2'), 'utf8'), edit.content);
        fixture.pick(imported);
        assert.equal(await fixture.view.importLocal(), undefined);
        const adding = fixture.view.addSubscription('https://new.invalid/source');
        const newSource = await fixture.take('/source');
        newSource.respondSource('proxies: []\nmode: rule\n');
        assert.equal(await adding, undefined);
        assert.ok((await fixture.store.readListAsync(dir)).subscriptions.some((sub) => sub.url === 'https://new.invalid/source'));
      } finally { await fixture.close(); }
    });
  });

test('real running-to-unknown handoff never starts the local updater and confirmed stop resumes the due subscription',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { subscription: true, autoUpdate: true, initialHost: 'running' });
      try {
        await fixture.connect(profileRuntime('p1', 1));
        fixture.emit({ type: 'runtime', status: profileRuntime('p2', 2) });
        assert.equal(fixture.view.running, 'p2');
        const before = await profileBusinessFiles(dir);
        fixture.unknown();
        fixture.view.setForeground(false);
        fixture.view.setForeground(true);
        await fixture.idle();
        assert.equal(fixture.requests.filter((request) => request.path === '/source').length, 0);
        assert.equal(await fixture.view.update('p1'), 'host_unknown');
        assert.equal(await fixture.view.select('p3'), 'host_unknown');
        assert.equal(await fixture.view.remove('p3'), 'host_unknown');
        assert.deepEqual(await profileBusinessFiles(dir), before);
        fixture.stopped();
        const download = await fixture.take('/source');
        download.respondSource('proxies: []\nmode: global\n');
        await waitForProfileFixture(() => fixture.view.find('p1').state.updatedAt > 0);
        assert.equal(await fsp.readFile(store.yamlPath(dir, 'p1'), 'utf8'), 'proxies: []\nmode: global\n');
        assert.ok((await fixture.store.readStateAsync(dir, 's1')).updatedAt > 0);
      } finally { await fixture.close(); }
    });
  });

test('real local updater cancels an old round across unknown and restarts immediately when stop is confirmed again',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { subscription: true, autoUpdate: true });
      try {
        const oldDownload = await fixture.take('/source');
        const before = await profileBusinessFiles(dir);
        fixture.unknown();
        fixture.stopped();
        oldDownload.respondSource('proxies: []\nmode: direct\n');
        const newDownload = await fixture.take('/source');
        assert.deepEqual(await profileBusinessFiles(dir), before);
        newDownload.respondSource('proxies: []\nmode: global\n');
        await waitForProfileFixture(() => fixture.view.find('p1').state.updatedAt > 0);
        assert.equal(await fsp.readFile(store.yamlPath(dir, 'p1'), 'utf8'), 'proxies: []\nmode: global\n');
        assert.equal(fixture.requests.filter((request) => request.path === '/source').length, 2);
      } finally { await fixture.close(); }
    });
  });

test('real controller failure cannot fall back locally until a fresh recheck confirms the host stopped',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { subscription: true });
      try {
        await fixture.connect(profileRuntime('p1', 1));
        const before = await profileBusinessFiles(dir);
        const failedUpdate = fixture.view.update('p1');
        const remote = await fixture.take('/arkclash/profiles/update');
        fixture.unknown();
        remote.fail(new Error('controller unreachable'));
        assert.equal(await failedUpdate, 'host_unknown');
        assert.equal(fixture.requests.filter((request) => request.path === '/source').length, 0);
        assert.deepEqual(await profileBusinessFiles(dir), before);
        await fixture.connect(profileRuntime('p1', 2));
        const retry = fixture.view.update('p1');
        const retryRemote = await fixture.take('/arkclash/profiles/update');
        fixture.connection.connected = false;
        retryRemote.fail(new Error('host stopped during request'));
        const fallback = await fixture.take('/source');
        fallback.respondSource('proxies: []\nmode: direct\n');
        assert.equal(await retry, undefined);
        assert.equal(await fsp.readFile(store.yamlPath(dir, 'p1'), 'utf8'), 'proxies: []\nmode: direct\n');
      } finally { await fixture.close(); }
    });
  });

test('real core operations remain remote when forwarding is paused and Connection.connected is false',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { subscription: true });
      try {
        await fixture.connect(profileRuntime('p1', 1));
        fixture.connection.connected = false;
        fixture.connection.recheck = async () => { fixture.connection.rechecks++; return true; };
        fixture.view.setConnected(true, false);
        const updating = fixture.view.update('p1');
        const remote = await fixture.take('/arkclash/profiles/update');
        remote.respond({ subscription: 's1', ok: true, state: { updatedAt: 1, failures: 0 } });
        assert.equal(await updating, undefined);
        assert.equal(fixture.requests.filter((request) => request.path === '/source').length, 0);
      } finally { await fixture.close(); }
    });
  });

test('real profile commits roll back when host qualification changes during awaited file operations',
  { timeout: 20000 }, async () => {
    const cases = [
      { name: 'selection', method: 'rename', suffix: '/list.json', run: (fixture) => fixture.view.select('p2') },
      { name: 'metadata', method: 'rename', suffix: '/list.json',
        run: (fixture) => fixture.view.edit('p2', { name: 'renamed', url: '', autoUpdate: false, intervalMinutes: 1440 }) },
      { name: 'source', method: 'rename', suffix: '/p2.summary.json',
        run: (fixture) => fixture.view.edit('p2', { name: 'edited', url: '', autoUpdate: false, content: 'proxies: []\nmode: direct\n' }) },
      { name: 'order', method: 'rename', suffix: '/list.json', run: (fixture) => fixture.view.reorder(['p3', 'p2', 'p1']) },
      { name: 'delete', method: 'unlink', suffix: '/p3.yaml', run: (fixture) => fixture.view.remove('p3') },
      { name: 'file import', method: 'rename', suffix: '/list.json', run: async (fixture, dir) => {
        const source = path.join(dir, 'import.yaml');
        await fsp.writeFile(source, 'proxies: []\nmode: direct\n');
        fixture.pick(source);
        return await fixture.view.importLocal();
      } },
      { name: 'node selection', method: 'rename', suffix: '/p2.selected.json', run: async (fixture, dir) => {
        try {
          await fixture.store.writeSelected(dir, 'p2', { Group: 'Node' }, () => fixture.view.offlineWritable && !fixture.view.connected);
          return undefined;
        } catch (error) { return error.message; }
      } }
    ];
    for (const scenario of cases) {
      await sandbox(async (dir) => {
        const fixture = await actualProfileConsumer(dir);
        let hold;
        try {
          await fixture.idle();
          if (scenario.name === 'node selection') { await fixture.store.writeSelected(dir, 'p2', { Group: 'Before' }); }
          const before = await profileBusinessFiles(dir);
          hold = fixture.holdIO(scenario.method, (...args) => args.at(-1).endsWith(scenario.suffix), true);
          const changing = scenario.run(fixture, dir);
          await hold.entered;
          fixture.unknown();
          hold.release();
          assert.equal(await changing, 'canceled', scenario.name);
          await fixture.idle();
          assert.deepEqual(await profileBusinessFiles(dir), before, scenario.name);
        } finally { hold?.release(); await fixture.close(); }
      });
    }
  });

test('real legacy migration waits for a confirmed stop and preserves the original cached source',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { initialHost: 'unknown', legacy: true });
      try {
        await fixture.idle();
        assert.deepEqual(await profileBusinessFiles(dir), { 'default.yaml': 'proxies: []\n' });
        assert.equal(fixture.view.items.length, 0);
        assert.equal(fixture.requests.length, 0);
        fixture.stopped();
        await waitForProfileFixture(() => fixture.view.items.length === 1);
        const saved = await fixture.store.readListAsync(dir);
        assert.notEqual(saved.current, '');
        assert.equal(saved.profiles[0].name, 'default.yaml');
        assert.equal(await fsp.readFile(store.yamlPath(dir, saved.current), 'utf8'), 'proxies: []\n');
        assert.equal(await fsp.readFile(path.join(store.profilesDir(dir), 'default.yaml'), 'utf8'), 'proxies: []\n');
      } finally { await fixture.close(); }
    });
  });

test('real acknowledged source reload records an applied failure when host qualification is lost at the HTTP receipt boundary',
  { timeout: 15000 }, async () => {
    for (const transition of ['unknown', 'new route generation']) {
      await sandbox(async (dir) => {
        const fixture = await actualProfileConsumer(dir);
        try {
          await fixture.connect(profileRuntime('p1', 1));
          await fixture.idle();
          const before = await profileBusinessFiles(dir);
          const editedSource = 'proxies: []\nmode: global\n';
          const editing = fixture.view.edit('p1', { name: 'edited active source', url: '', autoUpdate: false,
            content: editedSource });
          const reload = await fixture.take('/arkclash/reload');
          const applied = JSON.parse(reload.options.extraData);
          assert.equal(applied.profile, 'p1');
          assert.equal(applied.expectedProfile, 'p1');
          assert.notEqual(applied.path, store.yamlPath(dir, 'p1'));
          assert.equal(await fsp.readFile(applied.path, 'utf8'), editedSource);
          assert.equal(await fsp.readFile(store.yamlPath(dir, 'p1'), 'utf8'), before['p1.yaml']);
          reload.respond({});
          if (transition === 'unknown') { fixture.unknown(); }
          else {
            fixture.view.setConnected(false, false);
            fixture.view.setConnected(true, false);
          }
          assert.equal(await editing, 'apply_failed', transition);
          assert.equal(fixture.view.applyError, 'apply_failed', transition);
          await fixture.idle();
          assert.deepEqual(await profileBusinessFiles(dir), before, transition);
          assert.equal(fixture.requests.filter((request) => request.path === '/arkclash/reload').length, 1,
            'An obsolete or unknown route cannot acknowledge a compensating reload');
        } finally { await fixture.close(); }
      });
    }
  });

test('real acknowledged reload compensates a conflicting disk commit through HTTP using the previous source',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir);
      try {
        await fixture.connect(profileRuntime('p1', 1));
        await fixture.idle();
        const before = await profileBusinessFiles(dir);
        const editing = fixture.view.edit('p1', { name: 'conflicting edit', url: '', autoUpdate: false,
          content: 'proxies: []\nmode: direct\n', baseContentRevision: '' });
        const reload = await fixture.take('/arkclash/reload');
        const applied = JSON.parse(reload.options.extraData);
        assert.equal(await fsp.readFile(applied.path, 'utf8'), 'proxies: []\nmode: direct\n');
        await fixture.store.withProfileStorage(dir, async () => {
          const latest = await fixture.store.readListAsync(dir);
          latest.profiles.find((profile) => profile.id === 'p1').contentRevision = 'competing.revision';
          await fixture.store.writeList(dir, latest);
        });
        reload.respond({});
        const compensation = await fixture.take('/arkclash/reload');
        const restored = JSON.parse(compensation.options.extraData);
        assert.equal(restored.profile, 'p1');
        assert.equal(restored.expectedProfile, 'p1');
        assert.equal(restored.path, store.yamlPath(dir, 'p1'));
        assert.equal(await fsp.readFile(restored.path, 'utf8'), before['p1.yaml']);
        compensation.respond({});
        assert.equal(await editing, 'conflict');
        assert.notEqual(fixture.view.applyError, 'apply_failed');
        const after = await profileBusinessFiles(dir);
        assert.equal(after['p1.yaml'], before['p1.yaml']);
        assert.equal(after['p1.summary.json'], before['p1.summary.json']);
        assert.equal(JSON.parse(after['list.json']).profiles.find((profile) => profile.id === 'p1').contentRevision,
          'competing.revision');
        assert.equal(fixture.requests.filter((request) => request.path === '/arkclash/reload').length, 2);
      } finally { await fixture.close(); }
    });
  });

const confirmEditorDismiss = exportedFunction(path.join(featureDir, 'ProfileEditor.ets'), 'confirmProfileEditorDismiss',
  'const $r = (key: string): string => key; const DialogAlignment = { Bottom: 0 }; const sheetMaterial = (): undefined => undefined;');

test('dirty editor dismissal keeps the draft on cancellation and discards only after the chosen sheet closes', () => {
  let panel;
  let dismissed = 0;
  let saved = 0;
  const context = { showActionSheet: (options) => { panel = options; } };
  const draft = { saving: false, dirty: () => true, save: async () => { saved++; return true; } };
  confirmEditorDismiss(context, draft, () => { dismissed++; });
  panel.onWillDismiss({ dismiss() {} });
  panel.onDidDisappear();
  assert.equal(dismissed, 0);
  assert.equal(saved, 0);
  confirmEditorDismiss(context, draft, () => { dismissed++; });
  panel.sheets.find((item) => item.title === 'app.string.profile_discard').action();
  assert.equal(dismissed, 0);
  panel.onDidDisappear();
  assert.equal(dismissed, 1);
  assert.equal(saved, 0);
});

test('saving from dirty editor dismissal keeps failed changes open and closes only after a successful save', async () => {
  let panel;
  let dismissed = 0;
  let saved = 0;
  let success = false;
  const context = { showActionSheet: (options) => { panel = options; } };
  const draft = { saving: false, dirty: () => true, save: async () => { saved++; return success; } };
  const chooseSave = async () => {
    confirmEditorDismiss(context, draft, () => { dismissed++; });
    panel.sheets.find((item) => item.title === 'app.string.action_save').action();
    panel.onDidDisappear();
    await flushProfileCallbacks();
  };
  await chooseSave();
  assert.equal(saved, 1);
  assert.equal(dismissed, 0);
  success = true;
  await chooseSave();
  assert.equal(saved, 2);
  assert.equal(dismissed, 1);
});
