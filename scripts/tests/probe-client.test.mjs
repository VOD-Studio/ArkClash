// 执行真实 SDK 探测适配器；仅替换平台事件源，不产生外部网络请求。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = process.argv[2] ?? process.env.ARKCLASH_TYPESCRIPT ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';
const ts = require(compiler);
const client = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../entry/src/main/ets/client');
const requests = [];
const timers = new Map();
let timerId = 0;
let now = 1000;
class Clock extends Date { static now() { return now; } }
const http = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD', POST: 'POST' },
  createHttp() {
    const request = {
      destroyed: false, listeners: new Map(),
      on(name, callback) { this.listeners.set(name, callback); },
      off(name) { this.listeners.delete(name); },
      emit(name, value) { this.listeners.get(name)?.(value); },
      requestInStream(url, options) {
        this.url = url; this.options = options;
        return new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
      },
      destroy() { this.destroyed = true; }
    };
    requests.push(request);
    return request;
  }
};
const context = vm.createContext({
  Date: Clock, JSON, Math, Number, String, Array, Object, Error, RegExp, Uint8Array, ArrayBuffer,
  setTimeout: (callback) => { timers.set(++timerId, callback); return timerId; },
  clearTimeout: (id) => timers.delete(id)
});
const modules = new Map();
function load(name) {
  if (modules.has(name)) { return modules.get(name).exports; }
  const file = path.join(client, name + '.ets');
  const record = { exports: {} }; modules.set(name, record);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }, fileName: file + '.ts'
  }).outputText;
  const scopedRequire = (dependency) => {
    if (dependency === '@kit.BasicServicesKit') { return {}; }
    if (dependency === '@kit.NetworkKit') { return { http }; }
    if (dependency === '@kit.ArkTS') { return {
      url: { URL: { parseURL: (address, base) => new URL(address, base) } },
      util: { TextDecoder: { create: () => {
        const decoder = new TextDecoder();
        return { decodeToString: (bytes, options) => decoder.decode(bytes, options) };
      } } }
    }; }
    return load(dependency.replace(/^\.\//, ''));
  };
  new vm.Script(`(function(require,module,exports){${compiled}\n})`, { filename: file })
    .runInContext(context)(scopedRequire, record, record.exports);
  return record.exports;
}
const { DirectProbeRequest } = load('DirectProbe');
const flush = () => new Promise((resolve) => setImmediate(resolve));
const bytes = (text) => new TextEncoder().encode(text).buffer;
function headers(request, status = 200, extra = {}) {
  request.emit('headersReceive', { 'status-line': `HTTP/2 ${status}`, ...extra });
}
function end(request, status = 200) { request.emit('dataEnd'); request.resolve(status); }
const base = { url: 'https://first.example/probe', method: 'GET', bodyMode: 'none' };

const redirecting = new DirectProbeRequest().run({ ...base, method: 'POST', body: '{"data":true}',
  headers: { Authorization: 'target-only', 'Content-Type': 'application/json', 'User-Agent': 'browser-fixture' } }, 1000);
const first = requests.at(-1); now += 20;
headers(first, 302, { location: 'https://second.example/next' }); first.resolve(302);
await flush(); const second = requests.at(-1);
assert.equal(second.url, 'https://second.example/next');
assert.equal(second.options.method, 'GET'); assert.equal(second.options.extraData, undefined);
assert.equal(second.options.header.Authorization, undefined); assert.equal(second.options.header['Content-Type'], undefined);
assert.equal(second.options.header['User-Agent'], 'browser-fixture');
now += 15; headers(second, 307, { location: 'https://first.example/final' }); second.resolve(307);
await flush(); const third = requests.at(-1);
assert.equal(third.options.header.Authorization, undefined, '跨源后回跳也不能恢复凭据');
now += 5; headers(third); third.resolve(200);
const redirected = await redirecting;
assert.equal(redirected.url, 'https://first.example/final'); assert.equal(redirected.delay, 40);
assert.ok(first.destroyed && second.destroyed && third.destroyed);

const noRedirect = new DirectProbeRequest().run({ ...base, noRedirect: true }, 1000);
const stopped = requests.at(-1); const beforeRedirect = requests.length;
headers(stopped, 302, { location: '/jp/title/1' }); stopped.resolve(302);
const stoppedResult = await noRedirect;
assert.equal(stoppedResult.location, '/jp/title/1'); assert.equal(stoppedResult.status, 302);
assert.equal(stoppedResult.url, base.url); assert.equal(requests.length, beforeRedirect);

for (const [bodyMode, limit] of [['small', 16 * 1024], ['html', 512 * 1024]]) {
  const run = new DirectProbeRequest().run({ ...base, bodyMode }, 1000);
  const request = requests.at(-1); headers(request);
  request.emit('dataReceive', bytes('x'.repeat(limit + 100)));
  const result = await run;
  assert.equal(result.body, 'x'.repeat(limit), `${bodyMode} 返回合法前缀而不是超限失败`);
  assert.equal(request.destroyed, true); request.resolve(200);
}

const marker = ',2,1,200,"JPN';
const scan = new DirectProbeRequest().run({ ...base, bodyMode: 'scan', scanPattern: ',2,1,200,"[A-Z]{3}' }, 1000);
const scanRequest = requests.at(-1); headers(scanRequest);
scanRequest.emit('dataReceive', bytes('x'.repeat(32764) + marker.slice(0, 4)));
assert.equal(scanRequest.destroyed, false);
scanRequest.emit('dataReceive', bytes(marker.slice(4) + 'private-page-tail'));
const scanResult = await scan;
assert.equal(scanResult.body, marker + 'private-page-tail'); assert.equal(scanRequest.destroyed, true);
scanRequest.resolve(200);

const limited = new DirectProbeRequest().run({ ...base, bodyMode: 'scan', scanPattern: 'not-in-budget' }, 1000);
const limitedRequest = requests.at(-1); headers(limitedRequest);
const chunk = bytes('x'.repeat(64 * 1024));
for (let index = 0; index < 128; index++) { limitedRequest.emit('dataReceive', chunk); }
limitedRequest.emit('dataReceive', bytes('not-in-budget'));
assert.equal((await limited).body, ''); assert.equal(limitedRequest.destroyed, true); limitedRequest.resolve(200);

const jsonBody = JSON.stringify({ label: '中文', value: 42 });
const encoded = new TextEncoder().encode(jsonBody);
const jsonRun = new DirectProbeRequest().run({ ...base, bodyMode: 'json' }, 1000);
const jsonRequest = requests.at(-1); headers(jsonRequest);
for (let index = 0; index < encoded.length; index++) {
  jsonRequest.emit('dataReceive', encoded.slice(index, index + 1).buffer);
}
end(jsonRequest);
assert.equal((await jsonRun).body, jsonBody, 'UTF-8 字符跨块不能损坏正文');

const tooLarge = new DirectProbeRequest().run({ ...base, bodyMode: 'json' }, 1000);
const oversizeRejected = assert.rejects(tooLarge, (error) => error.reason === 'invalidResponse');
const oversizeRequest = requests.at(-1); headers(oversizeRequest);
oversizeRequest.emit('dataReceive', bytes('x'.repeat(64 * 1024 + 1)));
await oversizeRejected; assert.equal(oversizeRequest.destroyed, true); oversizeRequest.resolve(200);

const owner = new DirectProbeRequest();
const cancelRun = owner.run({ ...base, bodyMode: 'json' }, 1000);
const cancelled = assert.rejects(cancelRun, (error) => error.reason === 'cancelled');
const cancelRequest = requests.at(-1); owner.cancel(); await cancelled;
assert.equal(cancelRequest.destroyed, true); cancelRequest.resolve(200);

const timed = new DirectProbeRequest().run({ ...base, bodyMode: 'json' }, 1000);
const timedOut = assert.rejects(timed, (error) => error.reason === 'timeout');
const timeoutRequest = requests.at(-1); [...timers.values()].at(-1)(); await timedOut;
assert.equal(timeoutRequest.destroyed, true); timeoutRequest.resolve(200);

for (const status of [307, 308]) {
  const run = new DirectProbeRequest().run({ ...base, method: 'POST', body: 'refresh_token=private-fixture' }, 1000);
  const request = requests.at(-1); headers(request, status, { location: '/same-origin' }); request.resolve(status);
  await flush(); const relay = requests.at(-1);
  assert.equal(relay.options.method, 'POST'); assert.equal(relay.options.extraData, 'refresh_token=private-fixture');
  const count = requests.length;
  headers(relay, status, { location: 'https://other.example/collect' }); relay.resolve(status);
  assert.equal((await run).status, status);
  assert.equal(requests.length, count, '跨源 307/308 不得转发含令牌正文');
}

const restrictionBody = '{"currentTerritory":"US","isServiceRestricted":true}';
const restriction = new DirectProbeRequest().run({ ...base, bodyMode: 'scan',
  scanPattern: 'isServiceRestricted|\"currentTerritory\":\"[^\"]+\"' }, 1000);
const restrictionRequest = requests.at(-1); headers(restrictionRequest);
restrictionRequest.emit('dataReceive', bytes(restrictionBody));
assert.ok((await restriction).body.includes('isServiceRestricted'), '地区字段不能盖过同窗口的拒绝证据');
restrictionRequest.resolve(200);

for (const bodyMode of ['none', 'small', 'scan', 'json']) {
  const run = new DirectProbeRequest().run({ ...base, bodyMode, scanPattern: 'evidence' }, 1000);
  const request = requests.at(-1); const started = now; now += 25;
  request.emit('headersReceive', { 'content-type': 'text/plain' });
  request.emit('dataReceive', bytes('evidence' + 'x'.repeat(20000)));
  assert.equal(request.destroyed, false, '无状态行时不能以状态0提前结算');
  now += 75; end(request, 200);
  const result = await run;
  assert.equal(result.status, 200); assert.equal(result.delay, 25);
  assert.equal(now - started, 100);
  assert.equal(result.body, bodyMode === 'none' ? '' :
    bodyMode === 'small' ? ('evidence' + 'x'.repeat(20000)).slice(0, 16 * 1024) : 'evidence' + 'x'.repeat(20000));
}

const implicitRedirect = new DirectProbeRequest().run(base, 1000);
const implicitFirst = requests.at(-1);
implicitFirst.emit('headersReceive', { location: '/final-without-status-line' });
end(implicitFirst, 302); await flush();
const implicitLast = requests.at(-1);
assert.equal(implicitLast.url, 'https://first.example/final-without-status-line');
implicitLast.emit('headersReceive', { location: '/not-a-redirect' });
end(implicitLast, 201);
assert.equal((await implicitRedirect).status, 201, 'Location 本身不能被误判为重定向');

const missingCode = new DirectProbeRequest().run({ ...base, bodyMode: 'none' }, 1000);
const missingCodeRejected = assert.rejects(missingCode, (error) => error.reason === 'invalidResponse');
const missingCodeRequest = requests.at(-1);
missingCodeRequest.emit('headersReceive', {});
for (let index = 0; index < 129; index++) { missingCodeRequest.emit('dataReceive', chunk); }
await missingCodeRejected; assert.equal(missingCodeRequest.destroyed, true); missingCodeRequest.resolve(200);

await flush(); assert.equal(timers.size, 0, '完成、取消及超时都必须释放定时器');
console.log('probe-client: 直连重定向、凭据隔离、流式前缀与扫描、完整JSON、取消和超时通过');
