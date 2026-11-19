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
  stat: (value) => typeof value === 'string' ? fsp.stat(value) :
    new Promise((resolve, reject) => fs.fstat(value, (error, stat) => error ? reject(error) : resolve(stat))),
  read: (fd, bytes) => new Promise((resolve, reject) => fs.read(fd, Buffer.from(bytes), (error, length) =>
    error ? reject(error) : resolve(length))),
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
  '@kit.ArkTS': { taskpool: { execute: async (operation, ...args) => operation(...args) }, url: { URL }, util: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class extends TextDecoder { decodeToString(bytes) { return this.decode(bytes); } },
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
    if (name === 'yaml') { return require(path.resolve(scriptDir, '../entry/oh_modules/yaml/dist/index.js')); }
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

// 只提取实际组件的控制逻辑；原生布局与动效由真机验收。
function componentControl(name, overrides = {}) {
  const file = path.join(featureDir, `${name}.ets`);
  const text = fs.readFileSync(file, 'utf8').replace(new RegExp(`\\bstruct\\s+${name}\\b`), `class ${name}`);
  const ast = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declaration = ast.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === name);
  const members = declaration.members.filter(member => {
    const decorators = ts.getDecorators(member) ?? [];
    return member.name !== undefined && member.name.getText(ast) !== 'build' &&
      (ts.isPropertyDeclaration(member) || ts.isMethodDeclaration(member)) &&
      !decorators.some(decorator => decorator.expression.getText(ast) === 'Builder');
  }).map(member => {
    const decorators = ts.getDecorators(member) ?? [];
    return text.slice(decorators.at(-1)?.end ?? member.getStart(ast), member.end);
  }).join('\n');
  return load(file, `export class ${name} {\n${members}\n}`, overrides)[name];
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
    tunAttached: true, vpnCreated: true, listenersOpen: false, startedAt: 1, bootId, configRevision, revision,
    version: 'profile.fixture', mode: 'rule' };
}

function warmProfileRuntime(profile, configRevision, bootId = 'profile.boot.a', revision = configRevision) {
  return { ...profileRuntime(profile, configRevision, bootId, revision), intent: 'stopped', forward: 'stopped',
    tunAttached: false, vpnCreated: false, listenersOpen: false, startedAt: 0 };
}

async function actualProfileConsumer(filesDir,
  { subscription = false, autoUpdate = false, initialHost = 'stopped', legacy = false,
    profileIds = ['p1', 'p2', 'p3'], earlyUnknown = false } = {}) {
  const requests = [];
  const sockets = [];
  const moduleCache = new Map();
  const timers = new Map();
  let nextTimer = 0;
  let pendingIO = 0;
  let selectedUris = [];
  let saveUris = [];
  let ioHold;
  const connectionInput = { connected: initialHost === 'running', coreReady: initialHost === 'running',
    busy: false, bootId: 'profile.boot.a', error: '', disconnects: 0, disconnectFailure: '',
    recheckFailure: initialHost === 'unknown' ? new Error('unconfirmed host') : undefined, rechecks: 0,
    async recheck() { this.rechecks++; if (this.recheckFailure) { throw this.recheckFailure; } return this.coreReady; },
    async disconnect() {
      this.disconnects++;
      this.error = this.disconnectFailure;
      if (this.error === '') { this.connected = false; }
    } };
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
    await actualStore.writeList(filesDir, { version: 1, current: profileIds[0] ?? '',
      subscriptions: subscription ? [{ id: 's1', url: 'https://subscription.invalid/source', autoUpdate,
        intervalHours: 24, intervalMinutes: 1440, revision: 'subscription.1' }] : [], profiles:
      profileIds.map((id) => ({ id, name: id, nameEdited: false, subscription: subscription && id === 'p1' ? 's1' : '' })) });
    for (const id of profileIds) {
      await actualStore.writeProfileText(actualStore.yamlPath(filesDir, id), 'proxies: []\n');
      await actualStore.writeProfileText(actualStore.summaryPath(filesDir, id), JSON.stringify({ groups: [], proxies: 0, revision: `source.${id}` }));
    }
  }
  const { ProfileStore } = loadActual(path.join(featureDir, 'Profiles.ets'));
  const view = new ProfileStore();
  if (earlyUnknown) { view.setCoreReady(false, false); }
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
    async commitRemoteAdd(request, text = 'proxies: []\n') {
      const body = JSON.parse(request.options.extraData);
      const { DirectDownloader } = loadActual(path.join(etsDir, 'shared/profiles/Download.ets'));
      const { downloadNewSubscription } = loadActual(path.join(etsDir, 'shared/profiles/Updater.ets'));
      const adding = downloadNewSubscription({ filesDir, downloader: new DirectDownloader(), running: () => '' },
        body.profile, body.subscription, body.url, body.label);
      const source = await take(new URL(body.url).pathname);
      source.respondSource(text);
      const outcome = await adding;
      assert.equal(outcome.ok, true);
      request.respond(outcome);
      return body.profile;
    },
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
      connectionInput.coreReady = false;
      connectionInput.recheckFailure = new Error('unconfirmed host');
      view.setCoreReady(false, false);
    },
    stopped() {
      connectionInput.connected = false;
      connectionInput.coreReady = false;
      connectionInput.recheckFailure = undefined;
      view.setCoreReady(false, true);
    },
    emit(payload) {
      const wire = sockets.filter((socket) => socket.active).at(-1);
      assert.ok(wire, 'The real ProfileEvents consumer must subscribe before receiving runtime events');
      wire.emit(payload);
    },
    async connect(status) {
      connectionInput.recheckFailure = undefined;
      connectionInput.coreReady = true;
      connectionInput.connected = status.forward === 'running' && status.tunAttached && status.vpnCreated;
      connectionInput.bootId = status.bootId;
      view.setCoreReady(true);
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

test('initial unknown readiness cannot skip proven-stop migration before the profile store becomes loaded',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { legacy: true, earlyUnknown: true });
      try {
        assert.equal(fixture.view.loaded, true);
        assert.ok(fixture.connection.rechecks > 0);
        assert.equal(fixture.view.offlineWritable, true);
        assert.equal(fixture.view.items.length, 1);
        assert.notEqual((await fixture.store.readListAsync(dir)).current, '');
        assert.equal(fixture.view.find(fixture.view.current).name, 'default.yaml');
      } finally { await fixture.close(); }
    });
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { legacy: true, earlyUnknown: true, initialHost: 'unknown' });
      try {
        assert.equal(fixture.view.loaded, true);
        assert.ok(fixture.connection.rechecks > 0);
        assert.equal(fixture.view.offlineWritable, false);
        assert.equal(fixture.view.items.length, 0);
        assert.equal(fixture.view.applyError, 'host_unknown');
      } finally { await fixture.close(); }
    });
  });

test('first local import activates a warm empty core even while the initial runtime read is pending',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { profileIds: [] });
      try {
        fixture.connection.coreReady = true;
        fixture.view.setCoreReady(true);
        const initial = await fixture.take('/arkclash/status');
        const source = path.join(dir, 'first.yaml');
        await fsp.writeFile(source, 'proxies: []\nmode: direct\n');
        fixture.pick(source);
        const importing = fixture.view.importLocal();
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 1));
        const reload = await fixture.take('/arkclash/reload');
        const body = JSON.parse(reload.options.extraData);
        const saved = await fixture.store.readListAsync(dir);
        assert.equal(body.profile, saved.current);
        assert.equal(body.path, fixture.store.yamlPath(dir, saved.current));
        assert.equal(body.expectedProfile, '');
        assert.equal(await fsp.readFile(body.path, 'utf8'), 'proxies: []\nmode: direct\n');
        await fixture.store.withProfileStorage(dir, async () => {
          assert.equal((await fixture.store.readListAsync(dir)).current, body.profile);
        });
        initial.respond(profileRuntime('obsolete', 99));
        reload.respond({});
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime(body.profile, 2));
        assert.equal(await importing, undefined);
        assert.equal(fixture.view.coreReady, true);
        assert.equal(fixture.connection.connected, false);
        assert.equal(fixture.view.running, body.profile);
        assert.equal(fixture.view.current, body.profile);
        assert.equal(fixture.view.applyError, '');
        assert.equal(fixture.connection.disconnects, 0);
      } finally { await fixture.close(); }
    });
  });

test('first remote subscription commit activates the current profile after the real commit locks are released',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { profileIds: [] });
      try {
        await fixture.connect(warmProfileRuntime('', 1));
        const adding = fixture.view.addSubscription('https://subscription.invalid/first', 'First subscription');
        const remote = await fixture.take('/arkclash/profiles/add');
        const id = await fixture.commitRemoteAdd(remote, 'proxies: []\nmode: rule\n');
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 1));
        const reload = await fixture.take('/arkclash/reload');
        assert.deepEqual(JSON.parse(reload.options.extraData),
          { profile: id, path: fixture.store.yamlPath(dir, id), expectedProfile: '' });
        await fixture.store.withProfileStorage(dir, async () => {
          assert.equal((await fixture.store.readListAsync(dir)).current, id);
        });
        reload.respond({});
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime(id, 2));
        assert.equal(await adding, undefined);
        assert.equal(fixture.view.active().id, id);
        assert.equal(fixture.view.find(id).name, 'First subscription');
        assert.equal(fixture.connection.connected, false);
        assert.equal(fixture.requests.filter((request) => request.path === '/first').length, 1);
      } finally { await fixture.close(); }
    });
  });

test('new imports do not force a switch when the detached core already has a running profile',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir);
      try {
        await fixture.connect(warmProfileRuntime('p2', 1));
        const source = path.join(dir, 'additional.yaml');
        await fsp.writeFile(source, 'proxies: []\nmode: direct\n');
        fixture.pick(source);
        const importing = fixture.view.importLocal();
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('p2', 1));
        assert.equal(await importing, undefined);
        assert.equal(fixture.view.running, 'p2');
        assert.equal(fixture.view.current, 'p1');
        assert.equal(fixture.view.items.length, 4);
        assert.equal(fixture.requests.filter((request) => request.path === '/arkclash/reload').length, 0);
        assert.equal(fixture.connection.connected, false);
      } finally { await fixture.close(); }
    });
  });

test('first activation rereads a choice changed during its status query without rewriting that persistent choice',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { profileIds: [] });
      try {
        await fixture.connect(warmProfileRuntime('', 1));
        const source = path.join(dir, 'first.yaml');
        await fsp.writeFile(source, 'proxies: []\n');
        fixture.pick(source);
        const importing = fixture.view.importLocal();
        const beforeChoice = await fixture.take('/arkclash/status');
        await fixture.store.writeProfileText(fixture.store.yamlPath(dir, 'newer'), 'proxies: []\nmode: direct\n');
        await fixture.store.withProfileStorage(dir, async () => {
          const latest = await fixture.store.readListAsync(dir);
          latest.profiles.push({ id: 'newer', name: 'Newer choice', nameEdited: false, subscription: '', type: 'file' });
          latest.current = 'newer';
          await fixture.store.writeList(dir, latest);
        });
        beforeChoice.respond(warmProfileRuntime('', 1));
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 1));
        const reload = await fixture.take('/arkclash/reload');
        assert.equal(JSON.parse(reload.options.extraData).profile, 'newer');
        assert.equal(JSON.parse(reload.options.extraData).expectedProfile, '');
        reload.respond({});
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('newer', 2));
        assert.equal(await importing, undefined);
        assert.equal((await fixture.store.readListAsync(dir)).current, 'newer');
        assert.equal(fixture.view.current, 'newer');
        assert.equal(fixture.view.running, 'newer');
        assert.equal(fixture.requests.filter((request) => request.path === '/arkclash/reload').length, 1);
      } finally { await fixture.close(); }
    });
  });

test('a competing loaded runtime rejects stale empty-core activation and preserves the newer persistent choice',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir);
      try {
        await fixture.connect(warmProfileRuntime('', 1));
        const source = path.join(dir, 'additional.yaml');
        await fsp.writeFile(source, 'proxies: []\n');
        fixture.pick(source);
        const importing = fixture.view.importLocal();
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 1));
        const staleActivation = await fixture.take('/arkclash/reload');
        assert.equal(JSON.parse(staleActivation.options.extraData).expectedProfile, '');
        await fixture.store.withProfileStorage(dir, async () => {
          const latest = await fixture.store.readListAsync(dir);
          latest.current = 'p2';
          await fixture.store.writeList(dir, latest);
        });
        fixture.emit({ type: 'runtime', status: warmProfileRuntime('p2', 2) });
        staleActivation.fail(new Error('conflict'));
        assert.equal(await importing, 'conflict');
        await fixture.idle();
        assert.equal(fixture.view.applyError, 'conflict');
        assert.equal(fixture.view.running, 'p2');
        assert.equal((await fixture.store.readListAsync(dir)).current, 'p2');
        assert.equal(fixture.view.current, 'p2');
        assert.equal(fixture.requests.filter((request) => request.path === '/arkclash/reload').length, 1);
      } finally { await fixture.close(); }
    });
  });

test('failed first activation remains explicit and can be retried by selecting the saved profile',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir, { profileIds: [] });
      try {
        await fixture.connect(warmProfileRuntime('', 1));
        const source = path.join(dir, 'first.yaml');
        await fsp.writeFile(source, 'proxies: []\n');
        fixture.pick(source);
        const importing = fixture.view.importLocal();
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 1));
        const failed = await fixture.take('/arkclash/reload');
        const id = JSON.parse(failed.options.extraData).profile;
        failed.fail(new Error('rejected'));
        assert.equal(await importing, 'rejected');
        assert.equal(fixture.view.applyError, 'rejected');
        assert.equal(fixture.view.running, '');
        assert.equal(fixture.view.ready, false);
        assert.equal((await fixture.store.readListAsync(dir)).current, id);
        assert.equal(fixture.view.pending, '');
        const retrying = fixture.view.select(id);
        const retry = await fixture.take('/arkclash/reload');
        assert.equal(JSON.parse(retry.options.extraData).profile, id);
        retry.respond({});
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime(id, 2));
        assert.equal(await retrying, undefined);
        assert.equal(fixture.view.applyError, '');
        assert.equal(fixture.view.running, id);
        assert.equal(fixture.view.ready, true);
        assert.equal(fixture.connection.connected, false);
      } finally { await fixture.close(); }
    });
  });

test('detached source edits establish the pending runtime profile and reload through the controller before committing',
  { timeout: 10000 }, async () => {
    await sandbox(async (dir) => {
      const fixture = await actualProfileConsumer(dir);
      try {
        fixture.connection.coreReady = true;
        fixture.view.setCoreReady(true);
        const initial = await fixture.take('/arkclash/status');
        const content = 'proxies: []\nmode: direct\n';
        const editing = fixture.view.edit('p1', { name: 'Edited while detached', url: '', autoUpdate: false, content });
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('p1', 1));
        initial.respond(warmProfileRuntime('', 1));
        const reload = await fixture.take('/arkclash/reload');
        const body = JSON.parse(reload.options.extraData);
        assert.equal(body.profile, 'p1');
        assert.equal(body.expectedProfile, 'p1');
        assert.notEqual(body.path, fixture.store.yamlPath(dir, 'p1'));
        assert.equal(await fsp.readFile(body.path, 'utf8'), content);
        assert.equal(await fsp.readFile(fixture.store.yamlPath(dir, 'p1'), 'utf8'), 'proxies: []\n');
        reload.respond({});
        assert.equal(await editing, undefined);
        assert.equal(await fsp.readFile(fixture.store.yamlPath(dir, 'p1'), 'utf8'), content);
        const selecting = fixture.view.select('p2');
        (await fixture.take('/arkclash/reload')).respond({});
        (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('p2', 3));
        assert.equal(await selecting, undefined);
        assert.equal(fixture.view.running, 'p2');
        assert.equal(fixture.view.coreReady, true);
        assert.equal(fixture.connection.connected, false);
        assert.equal(fixture.connection.disconnects, 0);
      } finally { await fixture.close(); }
    });
  });

test('deleting the last profile detaches actual VPN resources and clears the runtime before files while retaining the warm core',
  { timeout: 20000 }, async () => {
    const scenarios = [
      { status: warmProfileRuntime('p1', 1), disconnects: 0 },
      { status: profileRuntime('p1', 1), disconnects: 1 },
      { status: { ...warmProfileRuntime('p1', 1), forward: 'failed', vpnCreated: true }, disconnects: 1 }
    ];
    for (const scenario of scenarios) {
      await sandbox(async (dir) => {
        const fixture = await actualProfileConsumer(dir, { profileIds: ['p1'] });
        try {
          await fixture.connect(scenario.status);
          const removing = fixture.view.remove('p1');
          (await fixture.take('/arkclash/status')).respond(scenario.status);
          (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('p1', 1, scenario.status.bootId, 2));
          const clear = await fixture.take('/arkclash/reload');
          assert.deepEqual(JSON.parse(clear.options.extraData), { profile: '', path: '', expectedProfile: 'p1' });
          assert.equal(fixture.connection.disconnects, scenario.disconnects);
          assert.equal(await fsp.readFile(fixture.store.yamlPath(dir, 'p1'), 'utf8'), 'proxies: []\n');
          assert.equal((await fixture.store.readListAsync(dir)).profiles.length, 1);
          await fixture.store.withProfileStorage(dir, async () => {
            assert.equal((await fixture.store.readListAsync(dir)).current, 'p1');
          });
          clear.respond({});
          (await fixture.take('/arkclash/status')).respond(warmProfileRuntime('', 2, scenario.status.bootId, 3));
          assert.equal(await removing, undefined);
          const saved = await fixture.store.readListAsync(dir);
          assert.equal(saved.current, '');
          assert.equal(saved.profiles.length, 0);
          assert.equal(fixture.view.running, '');
          assert.equal(fixture.view.coreReady, true);
          assert.equal(fixture.view.offlineWritable, false);
          assert.equal(fixture.connection.bootId, scenario.status.bootId);
          assert.equal(fixture.connection.connected, false);
          assert.equal(fixture.view.pending, '');
          await assert.rejects(fsp.access(fixture.store.yamlPath(dir, 'p1')));
        } finally { await fixture.close(); }
      });
    }
  });

test('failed last-profile cleanup preserves its files and persistent choice for an explicit retry',
  { timeout: 15000 }, async () => {
    for (const failure of ['destroy', 'reload']) {
      await sandbox(async (dir) => {
        const fixture = await actualProfileConsumer(dir, { profileIds: ['p1'] });
        try {
          const status = failure === 'destroy' ? profileRuntime('p1', 1) : warmProfileRuntime('p1', 1);
          await fixture.connect(status);
          if (failure === 'destroy') { fixture.connection.disconnectFailure = 'destroy failed'; }
          const before = await profileBusinessFiles(dir);
          const removing = fixture.view.remove('p1');
          (await fixture.take('/arkclash/status')).respond(status);
          if (failure === 'reload') {
            (await fixture.take('/arkclash/status')).respond(status);
            (await fixture.take('/arkclash/reload')).fail(new Error('rejected'));
          }
          assert.equal(await removing, failure === 'destroy' ? 'apply_failed' : 'rejected');
          assert.notEqual(fixture.view.applyError, '');
          assert.deepEqual(await profileBusinessFiles(dir), before);
          assert.equal(fixture.view.coreReady, true);
          assert.equal(fixture.view.pending, '');
        } finally { await fixture.close(); }
      });
    }
  });

test('real ProfileStore rejects the older status reply after two overlapping reload notifications', { timeout: 5000 }, async () => {
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    try {
      fixture.connection.connected = true;
      fixture.view.setCoreReady(true);
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
      fixture.view.setCoreReady(false);
      fixture.view.setCoreReady(true);
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
        fixture.connection.coreReady = false;
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
        fixture.view.setCoreReady(true, false);
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
          await fixture.store.writeSelected(dir, 'p2', { Group: 'Node' }, () => fixture.view.offlineWritable && !fixture.view.coreReady);
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
          (await fixture.take('/arkclash/status')).respond(profileRuntime('p1', 1));
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
            fixture.view.setCoreReady(false, false);
            fixture.view.setCoreReady(true, false);
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
        (await fixture.take('/arkclash/status')).respond(profileRuntime('p1', 1));
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

const testAppearance = { sheetMaterial: () => undefined, fontFamily: '', palette: {} };
const confirmEditorDismiss = exportedFunction(path.join(featureDir, 'ProfileEditor.ets'), 'confirmProfileEditorDismiss',
  'const $r = (key: string): string => key; const DialogAlignment = { Bottom: 0 }; const appAppearance = { sheetMaterial: (): undefined => undefined };');

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

test('配置批量失败在后台保留，恢复可见后只展示一次', async () => {
  const { ListSource } = load(path.join(etsDir, 'components/ListSource.ets'));
  const resources = (key) => key;
  const { describeError } = load(path.join(featureDir, 'ProfileErrors.ets'), undefined, { $r: resources });
  const Page = componentControl('ProfilesPage', {
    ListSource, describeError, $r: resources, appAppearance: testAppearance, setInterval: () => 1, clearInterval: () => {}
  });
  for (const count of [1, 2]) {
    let finish;
    const result = { failures: Array.from({ length: count }, (_, index) =>
      ({ id: `profile-${index}`, name: `Profile ${index}`, error: 'download' })) };
    const toasts = [];
    const page = new Page();
    page.store = { applyError: 'download', updateAll: () => new Promise(resolve => { finish = resolve; }) };
    page.getUIContext = () => ({ getPromptAction: () => ({ showToast: ({ message }) => toasts.push(message) }) });
    page.clockVisible(true);
    toasts.length = 0;
    const updating = page.updateAll();
    page.visible = false;
    page.onVisibilityChange();
    finish(result);
    await updating;
    assert.equal(page.resultShown, false);
    assert.deepEqual(toasts, []);
    page.visible = true;
    page.onVisibilityChange();
    assert.equal(page.resultShown, count > 1);
    assert.equal(page.result, result);
    assert.deepEqual(toasts, count === 1 ? ['app.string.profile_update_failed'] : []);
    page.resultShown = false;
    page.visible = false;
    page.onVisibilityChange();
    page.visible = true;
    page.onVisibilityChange();
    assert.equal(page.resultShown, false);
    assert.equal(toasts.length, count === 1 ? 1 : 0);
    page.aboutToDisappear();
  }
});

test('编辑保存失败在后台不提前消费，返回前台只提示一次并保留草稿', async () => {
  const resources = (key) => key;
  const { describeError } = load(path.join(featureDir, 'ProfileErrors.ets'), undefined, { $r: resources });
  const { errorString } = load(path.join(etsDir, 'shared/profiles/Errors.ets'));
  const Editor = componentControl('ProfileEditor', { describeError, errorString, $r: resources, appAppearance: testAppearance });
  await sandbox(async (dir) => {
    const fixture = await actualProfileConsumer(dir);
    const editor = new Editor();
    const toasts = [];
    try {
      editor.store = fixture.view;
      editor.draft = fixture.draft('p1');
      editor.visible = true;
      editor.getUIContext = () => ({ getPromptAction: () => ({ showToast: ({ message }) => toasts.push(message) }) });
      editor.aboutToAppear();
      editor.draft.name = '';
      const saving = editor.save();
      editor.visible = false;
      assert.equal(await saving, false);
      assert.deepEqual(toasts, []);
      assert.notEqual(editor.draft.error, '');
      assert.equal(editor.draft.saving, false);
      assert.equal(editor.draft.name, '');
      assert.equal(editor.draft.dirty(), true);
      editor.visible = true;
      editor.consumeFailure();
      assert.deepEqual(toasts, [describeError(editor.draft.error)]);
      editor.consumeFailure();
      assert.equal(toasts.length, 1);
    } finally {
      editor.aboutToDisappear();
      await fixture.close();
    }
  });
});


const scriptsPath = path.join(etsDir, 'shared/profiles/Scripts.ets');
const scripts = load(scriptsPath, fs.readFileSync(scriptsPath, 'utf8').replace(/^@Concurrent\s*$/gm, ''));

test('配置脚本创建、导入重名、排序、单选绑定和删除可跨读取恢复', async () => {
  await sandbox(async (dir) => {
    await store.writeList(dir, { version: 1, current: 'p1', profiles: [
      { id: 'p1', name: 'One', nameEdited: true, subscription: '' },
      { id: 'p2', name: 'Two', nameEdited: true, subscription: '' },
    ], subscriptions: [] });
    assert.equal(scripts.scriptIdentity(await scripts.readConfigScripts(dir), 'p1'), '');
    const created = await scripts.saveConfigScript(dir, undefined, 'Test', scripts.SCRIPT_TEMPLATE);
    await assert.rejects(scripts.saveConfigScript(dir, undefined, 'Test', 'const main = c => c'), /name_taken/);
    const imported = await scripts.saveConfigScript(dir, undefined, 'Test.js', 'const main = c => c', '', true);
    assert.equal(imported.scripts[1].name, 'Test(1)');
    await scripts.reorderConfigScripts(dir, imported.scripts[1], imported.scripts[0]);
    let state = await scripts.readConfigScripts(dir);
    assert.equal(state.scripts[0].name, 'Test(1)');
    const first = created.scripts[0];
    for (const profile of ['p1', 'p2']) {
      state = await scripts.saveScriptBinding(dir, scripts.scriptBinding(state, profile),
        { profile, mode: 'script', scriptId: first.id });
    }
    assert.equal(scripts.scriptIdentity(state, 'p2'), `script:${first.id}:${first.revision}`);
    state = await scripts.saveScriptBinding(dir, scripts.scriptBinding(state, 'p2'),
      { profile: 'p2', mode: 'standard', scriptId: first.id });
    assert.equal(scripts.scriptIdentity(state, 'p2'), '');
    state = await scripts.removeConfigScript(dir, first);
    assert.equal(scripts.scriptIdentity(state, 'p1'), undefined);
    const saved = scripts.scriptBinding(await scripts.readConfigScripts(dir), 'p1');
    assert.equal(saved.scriptId, first.id);
    state = await scripts.saveScriptBinding(dir, saved, { profile: 'p1', mode: 'script', scriptId: '' });
    assert.equal(scripts.scriptIdentity(state, 'p1'), 'script');
  });
});

test('同步错误保留脚本与 URL，旧下载不能覆盖用户更晚的编辑', async () => {
  await sandbox(async (dir) => {
    const source = 'https://example.test/original.js';
    const created = await scripts.saveConfigScript(dir, undefined, 'Script', scripts.SCRIPT_TEMPLATE, source);
    const original = created.scripts[0];
    await assert.rejects(scripts.downloadConfigScript(dir, { download: async (_url, file) => {
      await fsp.writeFile(file, Buffer.from([0xf0, 0x28, 0x8c, 0x28]));
    } }, 'https://example.test/edited.js', original), /script_encoding/);
    assert.equal((await scripts.readConfigScripts(dir)).scripts[0].url, source);
    await assert.rejects(scripts.downloadConfigScript(dir, { download: async (_url, file) => {
      await fsp.writeFile(file, 'const main = c => ({remote: true})');
      await scripts.saveConfigScript(dir, original, original.name, 'const main = c => ({local: true})', source);
    } }, source, original), /script_conflict/);
    const persisted = (await scripts.readConfigScripts(dir)).scripts[0];
    assert.equal(persisted.source, 'const main = c => ({local: true})');
    assert.equal(persisted.url, source);
    assert.ok((await fsp.readdir(store.profilesDir(dir))).every(name => !name.endsWith('.candidate')));
  });
});

const localProxyModel = load(path.join(etsDir, 'shared/profiles/LocalProxies.ets'));
const localProxySchema = load(path.join(etsDir, 'shared/profiles/LocalProxySchema.ets'));
const localProxyStore = load(path.join(etsDir, 'shared/profiles/LocalProxyStore.ets'));

test('自定义节点切换协议时清理失效选项并保留兼容值和未知字段', () => {
  const schema = localProxySchema;
  const ss = { name: '边缘', type: 'ss', server: '192.0.2.4', port: 443, password: 'placeholder',
    cipher: 'aes-256-gcm', plugin: 'v2ray-plugin', 'plugin-opts': { host: 'example.invalid' }, 'custom-key': [1, 2] };
  const vmess = schema.changeProxyType(ss, 'vmess');
  assert.equal(schema.PROXY_TYPES.length, 28);
  assert.equal(vmess.cipher, 'auto');
  assert.equal(vmess.alterId, 0);
  assert.equal(vmess.password, undefined);
  assert.equal(vmess['plugin-opts'], undefined);
  assert.equal(vmess.server, ss.server);
  assert.deepEqual(vmess['custom-key'], [1, 2]);

  const byId = (id) => schema.PROXY_FIELDS.find((field) => field.id === id);
  const ws = { ...vmess, network: 'ws',
    'ws-opts': { headers: { host: 'example.invalid', 'X-First': 'one' }, 'v2ray-http-upgrade': true,
      'v2ray-http-upgrade-fast-open': true } };
  assert.ok(schema.proxyOptions(ws).includes(byId('wsHttpUpgradeFastOpen')));
  const inGrpc = schema.changeProxyOption(ws, byId('network'), 'grpc');
  assert.equal(inGrpc['ws-opts'], undefined);
  assert.ok(schema.proxyOptions(inGrpc).includes(byId('grpcServiceName')));

  const http = { ...vmess, network: 'http', 'http-opts': { headers: { Host: ['example.invalid'],
    'X-Multi': ['one', 'two'], 'X-Old': ['old'] } } };
  const parsed = schema.parseProxyMap(http, byId('httpHeaders'), 'X-Multi: one, two\nX-New: three');
  assert.deepEqual(JSON.parse(JSON.stringify(parsed)), { Host: ['example.invalid'], 'X-Multi': ['one', 'two'],
    'X-New': ['three'] });
  assert.throws(() => schema.parseProxyMap(http, byId('httpHeaders'), 'Host: example.com'), /local_proxy_map/);
});

test('批量快编复用已有节点 ID，保留非分享字段与不可编码节点，并支持改名预览', async () => {
  const m = localProxyModel;
  const first = m.newLocalProxy({ name: '一', type: 'http', server: '192.0.2.10', port: 443,
    tls: true, headers: { 'X-Custom': ['a', 'b'] } }, ['sni']);
  const opaque = m.newLocalProxy({ name: '不可编码', type: 'direct' });
  const last = m.newLocalProxy({ name: '末尾', type: 'socks5', server: '192.0.2.20', port: 1080 });
  const previous = { version: 1, revision: 'r1', proxies: [first, opaque, last] };
  const links = ['https://192.0.2.10:443#一', '', 'socks5://192.0.2.20:1080#末尾'];
  const plan = await localProxyStore.readProxyLinkPlan(previous, links,
    'https://192.0.2.11:443#一\n\nsocks5://192.0.2.20:1080#新名');
  assert.deepEqual(Array.from(plan.lines, (line) => line.number), [1, 3]);
  const next = await localProxyStore.buildProxyLinkEdit(previous, links, plan, new Map([
    [1, [{ name: '一', type: 'http', server: '192.0.2.11', port: 443, tls: true }]],
    [3, [{ name: '新名', type: 'socks5', server: '192.0.2.20', port: 1080 }]]
  ]), new Map([[first.id, { name: '一', type: 'http', server: '192.0.2.10', port: 443, tls: true }]]));
  assert.deepEqual(Array.from(next, m.localProxyName), ['不可编码', '一', '新名']);
  assert.equal(next[1].id, first.id);
  assert.equal(next[1].definition.server, '192.0.2.11');
  assert.deepEqual(next[1].definition.headers, first.definition.headers);
  assert.deepEqual(next[1].emptyOptions, first.emptyOptions);
  assert.notEqual(next[2].id, last.id);
  assert.equal(m.localProxyMatches(next[1], 'HTTP 192.0.2.11'), true);
  assert.equal(m.localProxyProblem({ ...first.definition, port: 65536 }), 'local_proxy_port');
});

test('节点库原子提交拒绝旧版本与重名，保留已有顺序和空选项', async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'arkclash-local-proxy-'));
  try {
    const storage = localProxyStore;
    const base = await storage.readLocalProxies(dir);
    const first = await storage.saveLocalProxy(dir, base, '',
      { name: '局部', type: 'direct', 'opaque-value': ['opaque'] }, ['interfaceName']);
    await assert.rejects(storage.saveLocalProxy(dir, base, '', { name: '过期', type: 'direct' }, []), /local_proxy_conflict/);
    await assert.rejects(storage.saveLocalProxy(dir, first, '', { name: '局部', type: 'direct' }, []), /local_proxy_name_taken/);
    const second = await storage.saveLocalProxy(dir, first, '', { name: '域名', type: 'dns' }, []);
    const moved = await storage.commitLocalProxies(dir, second, second.proxies.slice().reverse());
    const reopened = await storage.readLocalProxies(dir);
    assert.equal(reopened.revision, moved.revision);
    assert.deepEqual(Array.from(reopened.proxies, localProxyModel.localProxyName), ['域名', '局部']);
    assert.deepEqual(Array.from(reopened.proxies[1].emptyOptions), ['interfaceName']);
    assert.deepEqual(Array.from(reopened.proxies[1].definition['opaque-value']), ['opaque']);
  } finally {
    await fsp.rm(dir, { recursive: true, force: true });
  }
});

const proxyFilterStoragePath = path.join(etsDir, 'shared/profiles/ProxyFilters.ets');
const filterLibrary = load(proxyFilterStoragePath, fs.readFileSync(proxyFilterStoragePath, 'utf8')
  .replace(/^@Concurrent\s*$/gm, ''));
const filterYaml = load(path.join(etsDir, 'shared/profiles/ProxyFilterYaml.ets'));
const testYaml = require(path.resolve(scriptDir, '../entry/oh_modules/yaml/dist/index.js'));

test('筛选预设可搜索、重排和清空，旧修订不能覆盖已保存的库', async () => {
  await sandbox(async (dir) => {
    const defaults = await filterLibrary.readProxyFilters(dir);
    assert.equal(defaults.presets.length, 11);
    assert.deepEqual(Array.from(filterLibrary.searchProxyFilters(defaults.presets, 'hong 港'), item => item.id), ['hk']);
    const custom = filterLibrary.newProxyFilter('  名称  ', '  (?i)hk  ');
    const first = await filterLibrary.commitProxyFilters(dir, defaults.revision, [custom, ...defaults.presets]);
    assert.equal((await filterLibrary.readProxyFilters(dir)).presets[0].label, '名称');
    assert.equal(filterLibrary.proxyFilterProblem(filterLibrary.newProxyFilter('名称', 'ok'), first.presets), 'proxy_filter_duplicate');
    await assert.rejects(filterLibrary.commitProxyFilters(dir, defaults.revision, []), /proxy_filter_conflict/);
    await filterLibrary.commitProxyFilters(dir, first.revision, []);
    assert.equal((await filterLibrary.readProxyFilters(dir)).presets.length, 0);
  });
});

test('筛选能追加到代理组、代理集合，也保留已有匹配、注释和 YAML 合并字段', () => {
  const source = [
    '# keep this comment',
    "template: &base {filter: '(?i)keep'}",
    'proxy-groups:',
    '  - name: Select',
    '    <<: *base',
    '    type: select',
    '    use: [source]',
    'proxy-providers:',
    '  source: {type: file, path: ./source.yaml}',
    'rules: [MATCH,DIRECT]',
    ''
  ].join('\r\n');
  const [group, provider] = filterYaml.filterTargets(source);
  assert.equal(group.name, 'Select');
  assert.equal(provider.name, 'source');
  const updated = filterYaml.filterIntoYaml(source, group, 'filter', "(?i)keep`HK'flag");
  const actual = testYaml.parse(updated, { merge: true });
  assert.equal(actual['proxy-groups'][0].filter, "(?i)keep`HK'flag");
  assert.equal(actual.template.filter, '(?i)keep');
  assert.match(updated, /^# keep this comment\r\n/);
  assert.match(updated, /<<: \*base/);
  assert.equal(filterYaml.filterIntoYaml(updated, group, 'filter', "HK'flag"), updated);
  const excluded = filterYaml.filterIntoYaml(updated, provider, 'exclude-filter', 'quota|reset');
  assert.equal(testYaml.parse(excluded)['proxy-providers'].source['exclude-filter'], 'quota|reset');
  assert.match(excluded, /rules: \[MATCH,DIRECT\]/);
});

test('筛选拒绝改写其他 YAML 对象正在共用的锚点', () => {
  const source = 'proxy-groups:\n  - &group { name: Base, type: select }\n  - { <<: *group, name: Other }\n';
  assert.throws(() => filterYaml.filterIntoYaml(source, filterYaml.filterTargets(source)[0], 'filter', 'HK'),
    /proxy_filter_yaml_value/);
});

const iconSetModel = load(path.join(etsDir, 'shared/profiles/IconSetModel.ets'));
const iconSetsFile = path.join(etsDir, 'shared/profiles/IconSets.ets');
const iconSetStore = load(iconSetsFile, fs.readFileSync(iconSetsFile, 'utf8').replace(/^@Concurrent\s*$/gm, ''));
const iconYaml = load(path.join(etsDir, 'shared/profiles/ProfileGroupIcons.ets'));

test('FlClash 图标集保留 HTTP(S) 图片、去重和文件名标签，并按代理组名称推荐', () => {
  const parsed = iconSetModel.parseIconSetManifest(JSON.stringify({ name: ' Icons ', icons: [
    { name: ' HK.png ', url: 'https://example.test/hk.png' },
    { name: 'Duplicate', url: 'https://example.test/hk.png' },
    { url: 'https://example.test/Hong_Kong.svg?ver=1' },
    { url: 'file:///settings.json' }, { url: 'ftp://example.test/other.png' }, null
  ] }));
  assert.equal(parsed.name, 'Icons');
  assert.deepEqual(Array.from(parsed.icons, icon => icon.name), ['HK.png', 'Hong_Kong.svg']);
  assert.equal(iconSetModel.iconSetLabel(parsed.icons[1].name), 'Hong Kong');
  const ranked = iconSetModel.rankIconSetImages(parsed.icons, '🇭🇰 Hong Kong');
  assert.deepEqual(Array.from(ranked, icon => icon.name), ['Hong_Kong.svg']);
  assert.throws(() => iconSetModel.parseIconSetManifest('{"name":"no icons"}'), /icon_set_invalid/);
});

test('图标集本地导入、重复 URL 同步、下载失败和并发修订保留原数据', async () => {
  await sandbox(async (dir) => {
    const manifest = (name, file) => JSON.stringify({ name, icons: [{ url: `https://example.test/${file}` }] });
    const localPath = path.join(dir, 'Local Icons.json');
    await fsp.writeFile(localPath, manifest('', 'local.svg'));
    const defaults = await iconSetStore.readIconSets(dir);
    const local = await iconSetStore.importIconSetFile(dir, defaults, localPath, path.basename(localPath));
    assert.equal(local.sets[0].name, 'Local Icons');
    const source = 'https://example.test/remote.json';
    const remote = { expectedRevision: local.revision, revision: 'remote-1', id: '', name: '', url: source };
    const downloader = { download: async (_source, target, identity) => {
      assert.ok(identity.maxBytes > 0);
      await fsp.writeFile(target, manifest('Remote', 'old.svg'));
    } };
    const saved = await iconSetStore.downloadIconSet(dir, downloader, remote);
    const failing = { download: async (_source, target) => { await fsp.writeFile(target, '<html>'); } };
    const update = { ...remote, expectedRevision: saved.revision, revision: 'remote-2' };
    await assert.rejects(iconSetStore.downloadIconSet(dir, failing, update), /icon_set_invalid/);
    assert.equal((await iconSetStore.readIconSets(dir)).revision, saved.revision);
    const newManifest = { download: async (_source, target) => { await fsp.writeFile(target, manifest('Renamed', 'new.svg')); } };
    const synced = await iconSetStore.downloadIconSet(dir, newManifest, update);
    assert.equal(synced.sets.length, 2);
    assert.equal(synced.sets[1].name, 'Remote');
    assert.equal(synced.sets[1].id, saved.sets[1].id);
    assert.match(synced.sets[1].icons[0].url, /new\.svg$/);
    await assert.rejects(iconSetStore.downloadIconSet(dir, downloader, remote), /icon_set_conflict/);
    const reordered = await iconSetStore.commitIconSets(dir, synced.revision, synced.sets.slice().reverse());
    assert.equal((await iconSetStore.readIconSets(dir)).sets[0].id, reordered.sets[0].id);
    assert.ok((await fsp.readdir(store.profilesDir(dir))).every(name => !name.endsWith('.candidate')));
  });
});

test('给代理组设置和清除图标只修改该组的 YAML 字段', () => {
  const source = [
    'proxy-groups:',
    '  - name: First',
    '    type: select # keep',
    '  - {name: Second, type: select, icon: "https://example.test/old.svg"}',
    'rules: [MATCH,DIRECT]',
    ''
  ].join('\n');
  const [first] = iconYaml.profileGroupIcons(source);
  const updated = iconYaml.setProfileGroupIcon(source, first, 'https://example.test/new.svg?x=1&y=2');
  const cleared = iconYaml.setProfileGroupIcon(updated, iconYaml.profileGroupIcons(updated)[1], '');
  assert.equal(testYaml.parse(cleared)['proxy-groups'][0].icon, 'https://example.test/new.svg?x=1&y=2');
  assert.equal(testYaml.parse(cleared)['proxy-groups'][1].icon, '');
  assert.match(cleared, /type: select # keep/);
  assert.match(cleared, /rules: \[MATCH,DIRECT\]/);
  assert.throws(() => iconYaml.setProfileGroupIcon(source, first, 'file:///secret'), /icon_set_input/);
});
