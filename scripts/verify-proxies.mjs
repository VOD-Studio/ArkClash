import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp, { readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

// 加载实际业务模块；平台文件接口绑定本机临时目录，HTTP 由消费者控制响应时机。
async function sourceModule(relative, prelude = '') {
  const source = await readFile(new URL(relative, import.meta.url), 'utf8');
  const withoutImports = source.replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '');
  const withoutObservers = withoutImports.replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  return `data:text/javascript;base64,${Buffer.from(prelude + stripTypeScriptTypes(withoutObservers)).toString('base64')}`;
}

const clientUrl = await sourceModule('../entry/src/main/ets/client/Proxies.ets');
const client = await import(clientUrl);
const logicUrl = await sourceModule('../entry/src/main/ets/features/proxies/ProxyLogic.ets',
  `import { isProxyGroup, proxyMemberNode, PROXY_TEST_URL } from ${JSON.stringify(clientUrl)};\n`);
const logic = await import(logicUrl);
const listUrl = await sourceModule('../entry/src/main/ets/components/ListSource.ets');
const viewUrl = await sourceModule('../entry/src/main/ets/features/proxies/ProxyView.ets',
  `import { ListSource } from ${JSON.stringify(listUrl)};\n` +
  `import { isProxyGroup, proxyMemberNode } from ${JSON.stringify(clientUrl)};\n` +
  `import { canTestProxy, proxyDelayKey, proxyGroupNames, proxyMembers, proxyPinnedMemberId, resolveProxyLeaf, selectableProxyGroup } from ${JSON.stringify(logicUrl)};\n`);
const view = await import(viewUrl);

const selectedRenameGates = new Map();
const openFiles = new Map();
const fileIo = {
  OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
    READ_WRITE: fs.constants.O_RDWR, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
  async access(file) { try { await fsp.access(file); return true; } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  } },
  mkdir: (file, recursive) => fsp.mkdir(file, { recursive }),
  async readText(file) { try { return await fsp.readFile(file, 'utf8'); } catch (error) {
    if (error.code === 'ENOENT') error.code = 13900002;
    throw error;
  } },
  async unlink(file) { try { await fsp.unlink(file); } catch (error) {
    if (error.code === 'ENOENT') error.code = 13900002;
    throw error;
  } },
  async open(file, flags) {
    const handle = await fsp.open(file, flags, 0o600);
    openFiles.set(handle.fd, handle);
    return { fd: handle.fd, handle, async lock(exclusive) { assert.equal(exclusive, true); } };
  },
  async close(file) { openFiles.delete(file.fd); await file.handle.close(); },
  async write(fd, bytes) { return (await openFiles.get(fd).write(Buffer.from(bytes))).bytesWritten; },
  async fsync(fd) { await openFiles.get(fd).sync(); },
  async rename(from, to) {
    const gate = selectedRenameGates.get(to);
    if (gate !== undefined) {
      selectedRenameGates.delete(to);
      if (gate.stage === 'before') { gate.enter(); await gate.released; }
    }
    await fsp.rename(from, to);
    if (gate?.stage === 'after') { gate.enter(); await gate.released; }
  }
};
const fileBridgeKey = Symbol('proxySelectedFileIo');
globalThis[fileBridgeKey] = fileIo;
const errorsUrl = await sourceModule('../entry/src/main/ets/shared/profiles/Errors.ets');
const storeUrl = await sourceModule('../entry/src/main/ets/shared/profiles/Store.ets',
  `import { ProfileError } from ${JSON.stringify(errorsUrl)};\n` +
  `const fs = globalThis[Object.getOwnPropertySymbols(globalThis).find(key => key.description === 'proxySelectedFileIo')];\n` +
  `const util = { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } };\n`);
const store = await import(storeUrl);

function holdSelectedRename(file, stage) {
  let enter;
  let release;
  const entered = new Promise(resolve => { enter = resolve; });
  const released = new Promise(resolve => { release = resolve; });
  selectedRenameGates.set(file, { stage, enter, released });
  return { entered, release };
}

let consumerFixtureId = 0;

async function consumerHarness() {
  const fixtureSource = `
    const fixtureId = ${++consumerFixtureId};
    let nextId = 0;
    let failures = 0;
    let heldFlush;
    const values = new Map();
    export { readSelected, writeSelected } from ${JSON.stringify(storeUrl)};
    export const commands = [];
    export const requests = [];
    export const CONTROLLER_ADDRESS = '127.0.0.1:19090';
    export function newId(prefix) { return prefix + fixtureId + '.' + (++nextId); }
    export async function readRuntime() { return { secret: 'fixture-only' }; }
    export async function getMode() { return 'rule'; }
    export function call(_dir, method, path, body) {
      return new Promise((resolve, reject) => commands.push({ method, path, body, resolve, reject }));
    }
    export function failNextFlush() { failures++; }
    export function holdNextFlush() {
      let release;
      const promise = new Promise(resolve => { release = resolve; });
      heldFlush = promise;
      return release;
    }
    const prefs = {
      async get(key, fallback) { return values.get(key) ?? fallback; },
      async put(key, next) { values.set(key, next); },
      async flush() {
        if (heldFlush !== undefined) {
          const pending = heldFlush;
          heldFlush = undefined;
          await pending;
        }
        if (failures > 0) {
          failures--;
          throw new Error('fixture_flush_failed');
        }
      }
    };
    export const preferences = { async getPreferences() { return prefs; } };
    export const http = {
      RequestMethod: { GET: 'GET', POST: 'POST' },
      HttpDataType: { STRING: 0 },
      createHttp() {
        let done = false;
        let rejectPending;
        return {
          request(url, options) {
            return new Promise((resolve, reject) => {
              rejectPending = reject;
              requests.push({
                url, options,
                reply(status, payload = '') {
                  if (!done) {
                    done = true;
                    resolve({ responseCode: status, result: payload });
                  }
                }
              });
            });
          },
          destroy() {
            if (!done && rejectPending !== undefined) {
              done = true;
              rejectPending(new Error('fixture_request_cancelled'));
            }
          }
        };
      }
    };
  `;
  const fixtureUrl = `data:text/javascript;base64,${Buffer.from(fixtureSource).toString('base64')}`;
  const native = await import(fixtureUrl);
  const boundClientUrl = await sourceModule('../entry/src/main/ets/client/Proxies.ets',
    `import { http, CONTROLLER_ADDRESS, readRuntime, newId, readSelected, writeSelected, call, getMode } from ${JSON.stringify(fixtureUrl)};\n`);
  const preferencesUrl = await sourceModule('../entry/src/main/ets/features/proxies/ProxyPreferences.ets',
    `import { preferences } from ${JSON.stringify(fixtureUrl)};\n` +
    `import { copyProxyStyle, defaultProxyStyle } from ${JSON.stringify(logicUrl)};\n`);
  const selection = await import(await sourceModule('../entry/src/main/ets/features/proxies/ProxySelection.ets',
    `import { observeProxySelections, submitProxySelection, proxyMemberNode, proxySelectionIdentity, matchesProxySelectionIdentity } from ${JSON.stringify(boundClientUrl)};\n` +
    `import { newId } from ${JSON.stringify(fixtureUrl)};\n` +
    `import { proxySelectionIntent, selectableProxyGroup } from ${JSON.stringify(logicUrl)};\n`));
  const appearance = await import(await sourceModule('../entry/src/main/ets/features/proxies/ProxyAppearance.ets',
    `import { copyProxyStyle, defaultProxyStyle } from ${JSON.stringify(logicUrl)};\n` +
    `import { loadProxyPreferences, saveProxyStyle, saveProxyView } from ${JSON.stringify(preferencesUrl)};\n`));
  const probes = await import(await sourceModule('../entry/src/main/ets/features/proxies/ProxyTests.ets',
    `import { cancelProxyDelayOwner, proxyMemberNode, testProxyDelays } from ${JSON.stringify(boundClientUrl)};\n` +
    `import { newId } from ${JSON.stringify(fixtureUrl)};\n` +
    `import { canTestProxy, defaultProxyStyle, proxyDelayKey, proxyGroupNames, proxyMembers, resolveProxyLeaf } from ${JSON.stringify(logicUrl)};\n`));
  return { fixtureUrl, native, client: await import(boundClientUrl), preferences: await import(preferencesUrl), ...selection, ...appearance, ...probes };
}

async function drainConsumers() {
  await new Promise(resolve => setImmediate(resolve));
}

function snapshot(profile = 'one') {
  return client.offlineProxySnapshot(profile, {
    revision: 'fixture.1',
    proxies: 4,
    nodes: [
      { name: 'Alpha US', type: 'VLESS' }, { name: 'beta HK', type: 'VMess' },
      { name: 'Gamma JP', type: 'Trojan' }, { name: 'REJECT', type: 'Reject' }
    ],
    groups: [
      { name: 'Main', type: 'select', members: ['Alpha US', 'beta HK', 'Gamma JP', 'REJECT'], dynamic: false },
      { name: 'Auto', type: 'url-test', members: ['Alpha US', 'beta HK'], dynamic: false, url: 'https://example.org/204' },
      { name: 'Fallback', type: 'fallback', members: ['Alpha US'], dynamic: false },
      { name: 'Balance', type: 'load-balance', members: ['Alpha US'], dynamic: false },
      { name: 'Chain', type: 'relay', members: ['Alpha US'], dynamic: false },
      { name: 'Hidden', type: 'select', members: ['Gamma JP'], hidden: true, dynamic: false }
    ]
  }, { Main: 'Alpha US', Auto: 'beta HK' }, 'rule', true);
}

function putDelay(state, group, name, delay, map) {
  const leaf = logic.resolveProxyLeaf(state, name, group.url);
  map.set(logic.proxyDelayKey(state, leaf), delay);
}

test('默认列表、none排序、标准样式、全部折叠', () => {
  assert.deepEqual(logic.defaultProxyStyle(), {
    type: 'list', sortType: 'none', layout: 'standard', cardType: 'standard', iconStyle: 'filled', hideTimeoutProxies: false
  });
  assert.deepEqual(logic.validProxyView({ expanded: [], currentGroup: '' }, ['Main', 'Auto'], 'rule'),
    { expanded: [], currentGroup: 'Main' });
});

test('五种组类型与手动选择权限，自动首选不冒充actual now', () => {
  const state = snapshot();
  for (const type of ['Selector', 'URLTest', 'Fallback']) assert.equal(logic.selectableProxyGroup(type), true);
  for (const type of ['LoadBalance', 'Relay']) assert.equal(logic.selectableProxyGroup(type), false);
  assert.equal(state.nodes.Main.now, 'Alpha US');
  assert.equal(state.nodes.Auto.now, '');
  assert.equal(state.selected.Auto, 'beta HK');
  assert.equal(client.canonicalProxyType('load-balance'), 'LoadBalance');
  assert.deepEqual(logic.proxySelectionIntent('Selector', 'A', 'A'), { changed: false, clearPin: false, name: 'A' });
  for (const type of ['URLTest', 'Fallback']) {
    assert.deepEqual(logic.proxySelectionIntent(type, '', 'A'), { changed: true, clearPin: false, name: 'A' });
    assert.deepEqual(logic.proxySelectionIntent(type, 'A', 'A'), { changed: true, clearPin: true, name: '' });
  }
  for (const type of ['LoadBalance', 'Relay']) {
    assert.equal(logic.proxySelectionIntent(type, 'A', 'B').changed, false);
  }
});

test('名称和类型按多词且不区分大小写匹配，不匹配组名', () => {
  const state = snapshot();
  assert.equal(logic.proxyMatches(state.nodes['Alpha US'], '  us  vLeSs '), true);
  assert.equal(logic.proxyMatches(state.nodes['Alpha US'], 'us vmess'), false);
  assert.equal(logic.proxyMembers(state, state.nodes.Main, 'Main', logic.defaultProxyStyle(), new Map()).length, 0);
  assert.equal(logic.proxyGroupNames(state).includes('Main'), true);
});

test('none保留核心顺序；name使用确定的字符串比较', () => {
  const state = snapshot();
  const style = logic.defaultProxyStyle();
  assert.deepEqual(logic.proxyMembers(state, state.nodes.Main, '', style, new Map()).map(node => node.name),
    ['Alpha US', 'beta HK', 'Gamma JP', 'REJECT']);
  style.sortType = 'name';
  assert.deepEqual(logic.proxyMembers(state, state.nodes.Main, '', style, new Map()).map(node => node.name),
    ['Alpha US', 'Gamma JP', 'REJECT', 'beta HK']);
});

test('599/600及0/-1/-2状态和颜色边界', () => {
  assert.equal(logic.proxyDelayDisplay(599).kind, 'success');
  assert.equal(logic.proxyDelayDisplay(600).kind, 'warning');
  assert.equal(logic.proxyDelayDisplay(0).kind, 'untested');
  assert.equal(logic.proxyDelayDisplay(-1).kind, 'timeout');
  assert.equal(logic.proxyDelayDisplay(-2).kind, 'failed');
});

test('HTTP未执行、取消与无结论不误报节点失败', () => {
  assert.equal(client.proxyDelayResponse(200, '{"delay":599}'), 599);
  assert.equal(client.proxyDelayResponse(200, '{"delay":0}'), undefined);
  assert.equal(client.proxyDelayResponse(504, ''), -1);
  assert.equal(client.proxyDelayResponse(503, ''), -2);
  for (const status of [400, 404, 409, 429, 500]) {
    assert.equal(client.proxyDelayResponse(status, ''), undefined);
  }
});

test('delay按正值、未测、超时、失败分层，同层保留核心顺序', () => {
  const state = snapshot();
  const group = state.nodes.Main;
  const style = logic.defaultProxyStyle();
  style.sortType = 'delay';
  const completed = new Map();
  putDelay(state, group, 'Alpha US', -2, completed);
  putDelay(state, group, 'beta HK', -1, completed);
  putDelay(state, group, 'Gamma JP', 600, completed);
  assert.deepEqual(logic.proxyMembers(state, group, '', style, completed).map(node => node.name),
    ['Gamma JP', 'REJECT', 'beta HK', 'Alpha US']);
});

test('隐藏使用完成批次，保留选择、未测及不可测；全失败和单一搜索仍可重测', () => {
  const state = snapshot();
  const group = state.nodes.Main;
  const style = logic.defaultProxyStyle();
  style.hideTimeoutProxies = true;
  const completed = new Map();
  putDelay(state, group, 'Alpha US', -1, completed);
  putDelay(state, group, 'beta HK', -2, completed);
  assert.deepEqual(logic.proxyMembers(state, group, '', style, completed).map(node => node.name),
    ['Alpha US', 'Gamma JP', 'REJECT']);
  assert.deepEqual(logic.proxyMembers(state, group, 'beta', style, completed).map(node => node.name), ['beta HK']);
  assert.equal(logic.proxyMembers(state, group, '', style, new Map()).length, 4);
  group.members = ['beta HK', 'Gamma JP'];
  group.now = '';
  state.selected.Main = '';
  putDelay(state, group, 'Gamma JP', -1, completed);
  assert.equal(logic.proxyMembers(state, group, '', style, completed).length, 2);
});

test('结果按配置、revision、URL与真实叶子隔离', () => {
  const one = snapshot('one');
  const two = snapshot('two');
  const first = logic.resolveProxyLeaf(one, 'Alpha US', 'https://a.example/204');
  const second = logic.resolveProxyLeaf(two, 'Alpha US', 'https://a.example/204');
  assert.notEqual(logic.proxyDelayKey(one, first), logic.proxyDelayKey(two, second));
  assert.notEqual(logic.proxyDelayKey(one, first),
    logic.proxyDelayKey(one, logic.resolveProxyLeaf(one, 'Alpha US', 'https://b.example/204')));
  const old = logic.proxyDelayKey(one, first);
  one.revision = 'updated';
  assert.notEqual(old, logic.proxyDelayKey(one, first));
  one.nodes.Auto.now = 'beta HK';
  const nested = logic.resolveProxyLeaf(one, 'Auto', 'https://outer.example/204');
  assert.equal(nested.name, 'beta HK');
  assert.equal(nested.url, 'https://example.org/204');
});

test('嵌套组环、缺失和未选择有明确结果，不递归卡死', () => {
  const state = snapshot();
  state.nodes.Main.now = 'Auto';
  state.nodes.Auto.now = 'Main';
  assert.equal(logic.resolveProxyLeaf(state, 'Main', '').reason, 'cycle');
  assert.equal(logic.resolveProxyLeaf(state, 'missing', '').reason, 'missing');
  state.nodes.Auto.now = '';
  assert.equal(logic.resolveProxyLeaf(state, 'Auto', '').reason, 'unselected');
});

test('订阅删当前组后回退有效组；规则/直连导航与搜索独立', () => {
  const state = snapshot();
  assert.equal(logic.proxyGroupNames(state).includes('Hidden'), false);
  assert.deepEqual(logic.validProxyView({ expanded: ['Main', 'deleted'], currentGroup: 'deleted' }, ['Main', 'Auto'], 'rule'),
    { expanded: ['Main'], currentGroup: 'Main' });
  state.mode = 'direct';
  assert.deepEqual(logic.proxyGroupNames(state), []);
});

test('网格布局及千节点排序保持完整稳定', () => {
  assert.equal(logic.proxyColumnCount(360, 'standard'), 2);
  assert.equal(logic.proxyColumnCount(360, 'loose'), 1);
  assert.equal(logic.proxyColumnCount(360, 'compact'), 3);
  assert.equal(logic.proxyColumnCount(800, 'standard'), 4);
  const state = snapshot();
  const group = state.nodes.Main;
  group.members = [];
  for (let index = 0; index < 1000; index++) {
    const name = `node-${String(index).padStart(4, '0')}`;
    group.members.unshift(name);
    state.nodes[name] = { ...state.nodes['Alpha US'], id: name, name };
  }
  const style = logic.defaultProxyStyle();
  style.sortType = 'name';
  const members = logic.proxyMembers(state, group, '', style, new Map());
  assert.equal(members.length, 1000);
  assert.equal(members[0].name, 'node-0000');
  assert.equal(members.at(-1).name, 'node-0999');
});

test('迟到选择广播不能修改同配置的新boot或新配置revision', async () => {
  for (const identity of [
    { bootId: 'boot.two', revision: 'config.one' },
    { bootId: 'boot.one', revision: 'config.two' },
    { bootId: 'boot.one', revision: 'config.one', configRevision: 2 }
  ]) {
    const harness = await consumerHarness();
    const previous = snapshot();
    previous.online = true;
    previous.bootId = 'boot.one';
    previous.revision = 'config.one';
    previous.configRevision = 1;
    let current = previous;
    let reloads = 0;
    const session = new harness.ProxySelectionSession(() => {}, () => {}, () => { reloads++; });
    session.observe(() => current);
    session.choose('/fixture', previous, 'Main', 'beta HK', true, () => current === previous);
    await drainConsumers();
    assert.equal(harness.native.commands.length, 1);
    current = snapshot();
    current.online = true;
    current.bootId = identity.bootId;
    current.revision = identity.revision;
    current.configRevision = identity.configRevision ?? 1;
    current.nodes.Main.now = 'Gamma JP';
    current.selected.Main = 'Gamma JP';
    harness.native.commands[0].resolve(JSON.stringify({
      changed: true, selected: 'beta HK', selectedId: 'beta HK', pinned: '', cleanupFailed: false
    }));
    await drainConsumers();
    assert.equal(current.nodes.Main.now, 'Gamma JP');
    assert.equal(current.selected.Main, 'Gamma JP');
    assert.ok(reloads > 0);
    session.unobserve();
  }
});

test('同一身份的选择成功仍同步实际采用节点', async () => {
  const harness = await consumerHarness();
  const current = snapshot();
  current.online = true;
  current.bootId = 'boot.one';
  const session = new harness.ProxySelectionSession(() => {}, () => {}, () => {});
  session.observe(() => current);
  session.choose('/fixture', current, 'Main', 'beta HK', true, () => true);
  await drainConsumers();
  harness.native.commands[0].resolve(JSON.stringify({
    changed: true, selected: 'beta HK', selectedId: 'beta HK', pinned: '', cleanupFailed: false
  }));
  await drainConsumers();
  assert.equal(current.nodes.Main.now, 'beta HK');
  assert.equal(session.pending.size, 0);
  session.unobserve();
});

test('展开草稿重试保留picker后来保存的当前组', async () => {
  const harness = await consumerHarness();
  const context = { filesDir: '/fixture' };
  const page = new harness.ProxyAppearance(() => {});
  const picker = new harness.ProxyAppearance(() => {});
  await Promise.all([page.load(context, 'one', () => true), picker.load(context, 'one', () => true)]);
  harness.native.failNextFlush();
  await page.persistView(context, 'one', { expanded: ['Main'] }, () => true);
  assert.equal(page.error, true);
  await picker.persistView(context, 'one', { currentGroup: 'Auto' }, () => true);
  const restored = await page.retry(context, 'one', () => true);
  assert.deepEqual(restored, { expanded: ['Main'], currentGroup: 'Auto' });
  const saved = await harness.preferences.loadProxyPreferences(context, 'one');
  assert.deepEqual(saved.view, { expanded: ['Main'], currentGroup: 'Auto' });
  assert.equal(page.error, false);
});

test('迟到视图重试不能覆盖重试期间的新展开意图', async () => {
  const harness = await consumerHarness();
  const context = { filesDir: '/fixture' };
  const page = new harness.ProxyAppearance(() => {});
  await page.load(context, 'one', () => true);
  harness.native.failNextFlush();
  await page.persistView(context, 'one', { expanded: ['Main'] }, () => true);
  const release = harness.native.holdNextFlush();
  const retry = page.retry(context, 'one', () => true);
  await drainConsumers();
  const newer = page.persistView(context, 'one', { expanded: ['Auto'] }, () => true);
  release();
  const result = await retry;
  await newer;
  assert.equal(result, undefined);
  const saved = await harness.preferences.loadProxyPreferences(context, 'one');
  assert.deepEqual(saved.view.expanded, ['Auto']);
});

test('重叠单节点和组测试不提前改变活动组的排序隐藏快照', async () => {
  for (const firstGroup of ['Quick', 'Main']) {
    const harness = await consumerHarness();
    const current = snapshot();
    current.online = true;
    current.bootId = 'boot.one';
    current.nodes.Main.members = ['beta HK', 'Gamma JP'];
    current.nodes.Main.now = 'Gamma JP';
    current.nodes.Main.nowId = 'Gamma JP';
    current.selected.Main = 'Gamma JP';
    current.nodes.Quick = { ...current.nodes.Main, id: 'Quick', name: 'Quick', members: ['beta HK'], now: 'beta HK', nowId: 'beta HK' };
    current.groups.push('Quick');
    const session = new harness.ProxyTestSession(() => {}, () => {});
    session.start('/fixture', current, firstGroup, '', 'beta HK');
    session.start('/fixture', current, 'Main', '');
    await drainConsumers();
    const style = logic.defaultProxyStyle();
    style.hideTimeoutProxies = true;
    const beta = harness.native.requests.find(request => new URL(request.url).searchParams.get('id') === 'beta HK');
    const gamma = harness.native.requests.find(request => new URL(request.url).searchParams.get('id') === 'Gamma JP');
    assert.ok(beta);
    assert.ok(gamma);
    beta.reply(503);
    await drainConsumers();
    assert.equal(session.testingGroups.has('Main'), true);
    assert.deepEqual(logic.proxyMembers(current, current.nodes.Main, '', style, session.completedFor('Main'))
      .map(node => node.name), ['beta HK', 'Gamma JP']);
    gamma.reply(200, '{"delay":120}');
    await drainConsumers();
    assert.equal(session.testingGroups.has('Main'), false);
    assert.deepEqual(logic.proxyMembers(current, current.nodes.Main, '', style, session.completedFor('Main'))
      .map(node => node.name), ['Gamma JP']);
    session.cancel();
  }
});

test('过期视图提交保留草稿，重试按最新revision只提交自己的字段', async () => {
  const harness = await consumerHarness();
  const context = { filesDir: '/fixture' };
  const page = new harness.ProxyAppearance(() => {});
  const picker = new harness.ProxyAppearance(() => {});
  await Promise.all([page.load(context, 'one', () => true), picker.load(context, 'one', () => true)]);
  await page.persistView(context, 'one', { expanded: ['Main'] }, () => true);
  await picker.persistView(context, 'one', { currentGroup: 'Auto' }, () => true);
  assert.equal(picker.error, true);
  const beforeRetry = await harness.preferences.loadProxyPreferences(context, 'one');
  assert.deepEqual(beforeRetry.view, { expanded: ['Main'], currentGroup: '' });
  const merged = await picker.retry(context, 'one', () => true);
  assert.deepEqual(merged, { expanded: ['Main'], currentGroup: 'Auto' });
  assert.equal(picker.error, false);
});

test('在线provider同名节点保留真实协议、历史和嵌套测速归属', async () => {
  const harness = await consumerHarness();
  const status = { profile: 'one', bootId: 'fixture', revision: 1, configRevision: 1 };
  const url = 'https://example.org/204';
  const ref = (id, name, provider = '') => ({ id, name, provider, selectable: true });
  const graph = {
    proxies: { Outer: ref('outer', 'Outer'), AutoA: ref('auto.a', 'AutoA'), AutoB: ref('auto.b', 'AutoB') },
    nodes: {
      outer: { name: 'Outer', type: 'Selector' },
      'auto.a': { name: 'AutoA', type: 'URLTest', testUrl: url },
      'auto.b': { name: 'AutoB', type: 'Fallback', testUrl: url },
      'node.a': { name: 'Shared', type: 'VLESS', extra: { [url]: { history: [{ delay: 55 }] } } },
      'node.b': { name: 'Shared', type: 'Trojan', extra: { [url]: { history: [{ delay: 123 }] } } }
    },
    members: {
      Outer: [ref('auto.a', 'AutoA'), ref('auto.b', 'AutoB')],
      AutoA: [ref('node.a', 'Shared', 'First')],
      AutoB: [ref('node.b', 'Shared', 'Second')]
    },
    actual: { Outer: 'auto.a', AutoA: 'node.a', AutoB: 'node.b' }
  };
  const pending = harness.client.readOnlineProxies('/fixture', 'one', undefined);
  await drainConsumers();
  harness.native.commands.shift().resolve(JSON.stringify(status));
  await drainConsumers();
  for (const command of harness.native.commands.splice(0)) {
    if (command.path === '/arkclash/proxies') command.resolve(JSON.stringify(graph));
    else if (command.path === '/arkclash/selections') command.resolve('{"profile":"one","selected":{}}');
    else assert.fail(`unexpected snapshot request ${command.path}`);
  }
  await drainConsumers();
  harness.native.commands.shift().resolve(JSON.stringify(status));
  const current = await pending;
  const first = logic.resolveProxyLeaf(current, 'auto.a', url, 'Outer');
  const second = logic.resolveProxyLeaf(current, 'auto.b', url, 'Outer');
  assert.equal(first.type, 'VLESS');
  assert.equal(second.type, 'Trojan');
  assert.equal(first.group, 'AutoA');
  assert.equal(second.group, 'AutoB');
  assert.notEqual(logic.proxyDelayKey(current, first), logic.proxyDelayKey(current, second));
  assert.equal(logic.proxyMembers(current, current.nodes.AutoA, 'vless', logic.defaultProxyStyle(), new Map())[0].name,
    'Shared');
  const session = new harness.ProxyTestSession(() => {}, () => {});
  session.seed(current);
  assert.equal(session.latest.get(logic.proxyDelayKey(current, first)), 55);
  assert.equal(session.latest.get(logic.proxyDelayKey(current, second)), 123);
  session.start('/fixture', current, 'Outer', '');
  await drainConsumers();
  assert.deepEqual(harness.native.requests.map(request => new URL(request.url).searchParams.get('group')).sort(),
    ['AutoA', 'AutoB']);
  session.cancel();
});

async function readConsumerGraph(harness, graph) {
  const status = { profile: 'one', bootId: 'fixture', revision: 1, configRevision: 1 };
  const pending = harness.client.readOnlineProxies('/fixture', 'one', undefined);
  await drainConsumers();
  harness.native.commands.shift().resolve(JSON.stringify(status));
  await drainConsumers();
  for (const command of harness.native.commands.splice(0)) {
    if (command.path === '/arkclash/proxies') command.resolve(JSON.stringify(graph));
    else if (command.path === '/arkclash/selections') command.resolve('{"profile":"one","selected":{}}');
    else assert.fail(`unexpected snapshot request ${command.path}`);
  }
  await drainConsumers();
  harness.native.commands.shift().resolve(JSON.stringify(status));
  return await pending;
}

function buildConsumerViews(current, session) {
  return view.buildProxyViews({
    snapshot: current, style: logic.defaultProxyStyle(), view: { expanded: current.groups, currentGroup: current.groups[0] },
    query: '', columns: 2, latest: session.latest, completedForGroup: name => session.completedFor(name),
    phases: session.phases, pending: new Map(), testingGroups: session.testingGroups, previous: [], picker: false
  });
}

test('同一URLTest和Fallback的两个provider同名项保留第二actual与独立结果，跨组同实例共享测速', async () => {
  const harness = await consumerHarness();
  const url = 'https://example.org/204';
  const ref = (id, name, provider = '', selectable = true) => ({ id, name, provider, selectable });
  const members = [ref('shared.first', 'Shared', 'First', false), ref('shared.second', 'Shared', 'Second', false)];
  const current = await readConsumerGraph(harness, {
    proxies: { Auto: ref('auto', 'Auto'), Fallback: ref('fallback', 'Fallback') },
    nodes: {
      auto: { name: 'Auto', type: 'URLTest', testUrl: url },
      fallback: { name: 'Fallback', type: 'Fallback', testUrl: url },
      'shared.first': { name: 'Shared', type: 'VLESS', extra: { [url]: { history: [{ delay: 55 }] } } },
      'shared.second': { name: 'Shared', type: 'Trojan', extra: { [url]: { history: [{ delay: 123 }] } } }
    },
    members: { Auto: members, Fallback: members }, actual: { Auto: 'shared.second', Fallback: 'shared.second' }
  });
  const tests = new harness.ProxyTestSession(() => {}, () => {});
  tests.seed(current);
  for (const group of buildConsumerViews(current, tests)) {
    assert.equal(group.nodes.length, 2);
    assert.deepEqual(group.nodes.map(node => node.name), ['Shared', 'Shared']);
    assert.deepEqual(group.nodes.map(node => node.selected), [false, true]);
    assert.deepEqual(group.nodes.map(node => node.selectable), [false, false]);
    assert.deepEqual(group.nodes.map(node => node.addressable), [false, false]);
    assert.deepEqual(group.nodes.map(node => node.testable), [true, true]);
    assert.deepEqual(group.nodes.map(node => node.delay), [55, 123]);
    assert.equal(group.rows.getData(0).nodes.length, 2);
    assert.notEqual(group.nodes[0].key, group.nodes[1].key);
  }
  const notices = [];
  const selection = new harness.ProxySelectionSession(() => {}, notice => notices.push(notice), () => {});
  selection.choose('/fixture', current, 'Auto', 'shared.second', true, () => true);
  selection.choose('/fixture', current, 'Auto', 'shared.first', true, () => true);
  assert.deepEqual(notices, ['notAddressable', 'notAddressable']);
  assert.equal(harness.native.commands.length, 0);
  tests.start('/fixture', current, 'Auto', '');
  tests.start('/fixture', current, 'Fallback', '');
  await drainConsumers();
  assert.equal(harness.native.requests.length, 2);
  for (const request of harness.native.requests) {
    const query = new URL(request.url).searchParams;
    assert.equal(query.get('expectedBootId'), 'fixture');
    assert.equal(query.get('expectedRevision'), '1');
    assert.equal(query.get('group'), 'Auto');
    if (query.get('id') === 'shared.first') request.reply(503);
    else if (query.get('id') === 'shared.second') request.reply(200, '{"delay":112}');
    else assert.fail(`wrong real member ID: ${query.get('id')}`);
  }
  await drainConsumers();
  for (const group of buildConsumerViews(current, tests)) {
    assert.deepEqual(group.nodes.map(node => node.delay), [-2, 112]);
    assert.deepEqual(group.nodes.map(node => node.selected), [false, true]);
  }
  current.online = false;
  current.offlineWritable = false;
  for (const group of buildConsumerViews(current, tests)) {
    assert.equal(group.nodes.length, 2);
    assert.deepEqual(group.nodes.map(node => node.selected), [false, true]);
    assert.deepEqual(group.nodes.map(node => node.selectable), [false, false]);
    assert.deepEqual(group.nodes.map(node => node.testable), [false, false]);
  }
  assert.equal(logic.resolveProxyLeaf(current, 'shared.second', url, 'Auto').id, 'shared.second');
  tests.cancel();
});

async function withSelectedProfile(operation) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'arkclash-proxy-consumer-'));
  try {
    await store.writeList(dir, { version: 1, current: 'one', subscriptions: [], profiles: [
      { id: 'one', name: 'One', nameEdited: false, subscription: '', type: 'local' }
    ] });
    await store.writeSelected(dir, 'one', { Main: 'Alpha US' });
    await operation(dir, store.selectedPath(dir, 'one'));
  } finally {
    await fsp.rm(dir, { recursive: true, force: true });
  }
}

test('unknown在真实Session入口和client最后写入均拒绝selected.json，确认stopped恢复', async () => {
  await withSelectedProfile(async (dir, file) => {
    const harness = await consumerHarness();
    let current = snapshot();
    current.offlineWritable = false;
    const before = await fsp.readFile(file, 'utf8');
    const notices = [];
    const session = new harness.ProxySelectionSession(() => {}, notice => notices.push(notice), () => {});
    session.observe(() => current);
    session.choose(dir, current, 'Main', 'beta HK', true, () => true);
    await drainConsumers();
    assert.deepEqual(notices, ['hostUnknown']);
    assert.equal(session.pending.size, 0);
    const command = {
      profile: 'one', group: 'Main', name: 'beta HK', nodeId: 'beta HK', clearPin: false,
      closeConnections: true, operationId: 'bypass-session', expectedBootId: '', expectedRevision: 0
    };
    await assert.rejects(harness.client.submitProxySelection(dir, command, current.nodes.Main,
      harness.client.proxySelectionIdentity(current), () => true), /proxy_selection_stale/);
    assert.equal(await fsp.readFile(file, 'utf8'), before);
    current = snapshot();
    session.choose(dir, current, 'Main', 'beta HK', true, () => current.offlineWritable);
    await harness.client.flushProxySelections(dir);
    await drainConsumers();
    assert.deepEqual(JSON.parse(await fsp.readFile(file, 'utf8')), { Main: 'beta HK' });
    assert.equal(current.nodes.Main.now, 'beta HK');
    session.unobserve();
  });
});

test('离线选择在rename前后身份变化均取消真实提交并保留旧文件，之后stopped可恢复', async () => {
  for (const stage of ['before', 'after']) {
    for (const change of ['unknown', 'running', 'revision']) {
      await withSelectedProfile(async (dir, file) => {
        const harness = await consumerHarness();
        let current = snapshot();
        const identity = harness.client.proxySelectionIdentity(current);
        const before = await fsp.readFile(file, 'utf8');
        const session = new harness.ProxySelectionSession(() => {}, () => {}, () => {});
        session.observe(() => current);
        const gate = holdSelectedRename(file, stage);
        session.choose(dir, current, 'Main', 'beta HK', true,
          () => harness.client.matchesProxySelectionIdentity(current, identity));
        const settling = harness.client.flushProxySelections(dir).then(() => undefined, error => error);
        await gate.entered;
        current = snapshot();
        if (change === 'unknown') current.offlineWritable = false;
        else if (change === 'running') { current.online = true; current.offlineWritable = false; current.bootId = 'new'; }
        else current.revision = 'new';
        gate.release();
        const error = await settling;
        assert.match(error?.message ?? '', /canceled|proxy_selection_stale/);
        assert.equal(await fsp.readFile(file, 'utf8'), before);
        assert.deepEqual((await fsp.readdir(path.dirname(file))).filter(name => name.endsWith('.tmp')), []);
        current = snapshot();
        session.choose(dir, current, 'Main', 'beta HK', true, () => current.offlineWritable);
        await harness.client.flushProxySelections(dir);
        await drainConsumers();
        assert.deepEqual(JSON.parse(await fsp.readFile(file, 'utf8')), { Main: 'beta HK' });
        session.unobserve();
      });
    }
  }
});

test('已有同名自动首选可明确清除组pin，actual仍标记第二实例', async () => {
  const harness = await consumerHarness();
  const current = snapshot();
  current.online = true;
  current.offlineWritable = false;
  current.bootId = 'fixture';
  current.nodes.Auto.members = ['first', 'second'];
  current.nodes.Auto.now = 'Shared';
  current.nodes.Auto.nowId = 'second';
  current.memberNodes.Auto = {
    first: { ...current.nodes['Alpha US'], id: 'first', name: 'Shared', selectable: false },
    second: { ...current.nodes['beta HK'], id: 'second', name: 'Shared', selectable: false }
  };
  current.selected.Auto = 'Shared';
  const tests = new harness.ProxyTestSession(() => {}, () => {});
  let group = buildConsumerViews(current, tests).find(item => item.name === 'Auto');
  assert.equal(group.pinned, 'Shared');
  assert.deepEqual(group.nodes.map(node => node.pinned), [false, false]);
  assert.deepEqual(group.nodes.map(node => node.selected), [false, true]);
  const session = new harness.ProxySelectionSession(() => {}, () => {}, () => {});
  session.observe(() => current);
  session.clearPin('/fixture', current, 'Auto', true, () => true);
  await drainConsumers();
  const command = harness.native.commands[0];
  assert.equal(command.path, '/arkclash/selection');
  assert.equal(JSON.parse(command.body).clearPin, true);
  assert.equal(JSON.parse(command.body).name, '');
  assert.equal(JSON.parse(command.body).nodeId, '');
  command.resolve('{"changed":true,"selected":"Shared","selectedId":"second","pinned":"","cleanupFailed":false}');
  await drainConsumers();
  group = buildConsumerViews(current, tests).find(item => item.name === 'Auto');
  assert.equal(group.pinned, '');
  assert.deepEqual(group.nodes.map(node => node.selected), [false, true]);
  session.unobserve();
  tests.cancel();
});

test('实际Controller首页摘要取自动组第二同名实例的历史', async () => {
  const harness = await consumerHarness();
  const controller = await import(await sourceModule('../entry/src/main/ets/client/Controller.ets',
    `import { http, CONTROLLER_ADDRESS, readRuntime } from ${JSON.stringify(harness.fixtureUrl)};\n`));
  const pending = controller.getMainGroup('/fixture');
  await drainConsumers();
  const mode = harness.native.requests.shift();
  assert.equal(new URL(mode.url).pathname, '/configs');
  mode.reply(200, '{"mode":"rule"}');
  await drainConsumers();
  const graph = harness.native.requests.shift();
  assert.equal(new URL(graph.url).pathname, '/arkclash/proxies');
  graph.reply(200, JSON.stringify({
    proxies: { GLOBAL: { id: 'global', name: 'GLOBAL' }, Auto: { id: 'auto', name: 'Auto' } },
    nodes: {
      global: { name: 'GLOBAL', type: 'Selector' }, auto: { name: 'Auto', type: 'URLTest' },
      first: { name: 'Shared', type: 'VLESS', history: [{ delay: 55 }] },
      second: { name: 'Shared', type: 'Trojan', history: [{ delay: 123 }] }
    },
    members: { GLOBAL: [{ id: 'auto', name: 'Auto' }], Auto: [
      { id: 'first', name: 'Shared' }, { id: 'second', name: 'Shared' }
    ] }, actual: { Auto: 'second' }
  }));
  assert.deepEqual(await pending, { group: 'Auto', node: 'Shared', delay: 123, retired: false, groups: ['Auto'] });
});

function retiredActualWireGraph() {
  const ref = (id, name, provider = '') => ({ id, name, provider, selectable: true });
  const url = 'https://example.org/204';
  return {
    proxies: { GLOBAL: ref('global', 'GLOBAL'), Outer: ref('outer', 'Outer'), Auto: ref('auto', 'Auto') },
    nodes: {
      global: { name: 'GLOBAL', type: 'Selector' },
      outer: { name: 'Outer', type: 'Selector' },
      auto: { name: 'Auto', type: 'URLTest', testUrl: url },
      'old.shared': { name: 'Shared', type: 'Direct', history: [{ delay: 77 }],
        extra: { [url]: { history: [{ delay: 77 }] } } },
      'new.shared': { name: 'Shared', type: 'Trojan' }
    },
    members: {
      GLOBAL: [ref('outer', 'Outer'), ref('auto', 'Auto')],
      Outer: [ref('auto', 'Auto')],
      Auto: [ref('new.shared', 'Shared', 'Remote')]
    },
    actual: { GLOBAL: 'outer', Outer: 'auto', Auto: 'old.shared' },
    retired: { 'old.shared': true }
  };
}

test('URLTest缓存中的退休actual保持摘要和嵌套解析，当前成员与实际出站分离且不重启旧测速', async () => {
  const harness = await consumerHarness();
  const current = await readConsumerGraph(harness, retiredActualWireGraph());
  assert.equal(current.nodes.Auto.now, 'Shared', '旧实例仍被实际采用时不能清空组摘要');
  assert.equal(current.nodes.Auto.nowId, 'old.shared');
  assert.deepEqual(current.nodes.Auto.members, ['new.shared']);
  const leaf = logic.resolveProxyLeaf(current, 'auto', 'https://outer.example/204', 'Outer');
  assert.equal(leaf.resolved, true);
  assert.equal(leaf.reason, '');
  assert.equal(leaf.id, 'old.shared');
  assert.equal(leaf.name, 'Shared');
  assert.equal(leaf.type, 'Direct');
  assert.equal(leaf.retired, true);
  const actual = harness.client.proxyMemberNode(current, 'Auto', 'old.shared');
  assert.equal(actual.retired, true);
  assert.equal(logic.canTestProxy(actual), false);
  const tests = new harness.ProxyTestSession(() => {}, () => {});
  tests.seed(current);
  const views = buildConsumerViews(current, tests);
  const automatic = views.find(group => group.name === 'Auto');
  assert.equal(automatic.now, 'Shared');
  assert.equal(automatic.actualRetired, true);
  assert.deepEqual(automatic.nodes.map(node => node.id), ['new.shared']);
  assert.equal(automatic.nodes[0].selected, false);
  const outer = views.find(group => group.name === 'Outer').nodes[0];
  assert.equal(outer.leafName, 'Shared');
  assert.equal(outer.leafRetired, true);
  assert.equal(outer.unresolved, false);
  assert.equal(outer.delay, 77);
  assert.equal(outer.testable, false);
  const selection = new harness.ProxySelectionSession(() => {}, () => {}, () => {});
  selection.choose('/fixture', current, 'Auto', 'old.shared', true, () => true);
  tests.start('/fixture', current, 'Auto', '', 'old.shared');
  tests.start('/fixture', current, 'Outer', '');
  await drainConsumers();
  assert.equal(harness.native.commands.length, 0);
  assert.equal(harness.native.requests.length, 0);
  tests.start('/fixture', current, 'Auto', '', 'new.shared');
  await drainConsumers();
  assert.equal(harness.native.requests.length, 1);
  assert.equal(new URL(harness.native.requests[0].url).searchParams.get('id'), 'new.shared');
  harness.native.requests[0].reply(200, '{"delay":112}');
  await drainConsumers();
  const refreshed = buildConsumerViews(current, tests);
  assert.equal(refreshed.find(group => group.name === 'Auto').nodes[0].delay, 112);
  assert.equal(refreshed.find(group => group.name === 'Outer').nodes[0].delay, 77);
  tests.cancel();
});

test('实际Controller摘要沿URLTest退休actual取旧实例，明确retired且不误取新同名历史', async () => {
  const harness = await consumerHarness();
  const controller = await import(await sourceModule('../entry/src/main/ets/client/Controller.ets',
    `import { http, CONTROLLER_ADDRESS, readRuntime } from ${JSON.stringify(harness.fixtureUrl)};\n`));
  const pending = controller.getMainGroup('/fixture');
  await drainConsumers();
  const mode = harness.native.requests.shift();
  assert.equal(new URL(mode.url).pathname, '/configs');
  mode.reply(200, '{"mode":"rule"}');
  await drainConsumers();
  const graph = harness.native.requests.shift();
  assert.equal(new URL(graph.url).pathname, '/arkclash/proxies');
  graph.reply(200, JSON.stringify(retiredActualWireGraph()));
  const summary = await pending;
  assert.equal(summary.group, 'Outer');
  assert.equal(summary.node, 'Shared');
  assert.equal(summary.delay, 77);
  assert.equal(summary.retired, true);
});
