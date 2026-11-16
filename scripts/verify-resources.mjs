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
function createResourcesHarness(dir) {
  const modules = new Map();
  const descriptors = new Map();
  const controls = { fail: undefined, shortWrite: false, writeGate: undefined, writing: false };
  function check(operation, file) {
    if (controls.fail?.(operation, file)) throw Object.assign(new Error('fixture I/O failure'), { code: 13900012 });
  }
  const fileIo = {
    OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, TRUNC: fs.constants.O_TRUNC },
    async readText(file) {
      check('read', file);
      try { return await fsp.readFile(file, 'utf8'); } catch (error) { platformError(error); }
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
      setInterval, clearInterval, require(name) {
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
  assert.equal(initial.autoUpdate, false);
  assert.equal(initial.intervalHours, 24);
  assert.deepEqual(await fsp.readdir(dir), []);
  initial.urls.mmdb = 'https://example.com/custom.mmdb?token=private';
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
