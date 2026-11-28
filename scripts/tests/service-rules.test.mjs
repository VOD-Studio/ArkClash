// 宿主直接执行实际 ArkTS 规则；会话替身只注入目标响应及流式片段，不访问网络。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = process.argv[2] ?? process.env.ARKCLASH_TYPESCRIPT ??
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js';
assert.ok(fs.existsSync(compiler), '请将 TypeScript 编译器路径作为第一个参数传入');
const ts = require(compiler);
const client = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../entry/src/main/ets/client');
const context = vm.createContext({ JSON, Math, Number, String, Array, Object, Error, RegExp, encodeURIComponent, decodeURIComponent });
const modules = new Map();
function load(name) {
  assert.match(name, /^(Service[A-Za-z]+|ProbeProtocol)$/);
  if (modules.has(name)) { return modules.get(name).exports; }
  const file = path.join(client, name + '.ets');
  const record = { exports: {} }; modules.set(name, record);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    fileName: file + '.ts', reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  });
  const errors = (compiled.diagnostics ?? []).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, ts.formatDiagnosticsWithColorAndContext(errors, {
    getCanonicalFileName: (fileName) => fileName, getCurrentDirectory: () => client, getNewLine: () => '\n'
  }));
  const scopedRequire = (dependency) => {
    assert.ok(dependency.startsWith('./'), '规则不得依赖系统、状态存储或 UI');
    return load(dependency.substring(2));
  };
  new vm.Script(`(function(require,module,exports){${compiled.outputText}\n})`, { filename: file })
    .runInContext(context)(scopedRequire, record, record.exports);
  return record.exports;
}
const { checkService } = load('ServiceRules');
const { normalizeServiceRegion } = load('ServiceRegion');
const BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const FALLBACK = 'https://legacy.example/service';
const URLS = {
  google: 'https://www.google.com/generate_204', github: 'https://github.com/',
  youtube: 'https://www.youtube.com/premium?hl=en', claude: 'https://claude.ai/cdn-cgi/trace',
  gemini: 'https://gemini.google.com', spotify: 'https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json',
  tiktok: 'https://www.tiktok.com/', discord: 'https://discord.com/api/v9/auth/location-metadata',
  'prime-video': 'https://www.primevideo.com',
  chatgpt: 'https://ios.chat.openai.com/', trace: 'https://chat.openai.com/cdn-cgi/trace',
  cookie: 'https://api.openai.com/compliance/cookie_requirements',
  title1: 'https://www.netflix.com/title/81280792', title2: 'https://www.netflix.com/title/70143836',
  titleRegion: 'https://www.netflix.com/title/80018499',
  devices: 'https://disney.api.edge.bamgrid.com/devices', token: 'https://disney.api.edge.bamgrid.com/token',
  graph: 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql',
  mainland: 'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi',
  hmt: 'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi'
};
let cases = 0;
const plain = (subject) => JSON.parse(JSON.stringify(subject));
const response = (body = '', status = 200, extra = {}) => ({ body, status, delay: 37, failure: '', ...extra });
const failure = (kind) => response('', 0, { failure: kind, delay: 9000 });

// 模拟共享会话的正文契约，验证真实规则生成的表达式及片段解释。传输实现由对应宿主套件验收。
function scanned(body, pattern) {
  assert.equal(typeof pattern, 'string');
  assert.ok(pattern.length > 0 && pattern.length <= 512);
  assert.equal(pattern.includes('(?i)'), false, '表达式必须兼容 JS 与 Go RE2');
  assert.equal(/\(\?[=!<]|\\[1-9]/.test(pattern), false, '扫描不得含 lookaround 或反向引用');
  const bytes = Buffer.from(body);
  const end = Math.min(bytes.length, 8 * 1024 * 1024);
  let overlap = Buffer.alloc(0);
  for (let offset = 0; offset < end; offset += 32 * 1024) {
    const chunk = bytes.subarray(offset, Math.min(end, offset + 32 * 1024));
    const window = Buffer.concat([overlap, chunk]);
    const match = new RegExp(pattern).exec(window.toString('utf8'));
    if (match !== null) { return window.toString('utf8').substring(match.index); }
    overlap = window.subarray(Math.max(0, window.length - 256));
  }
  return '';
}
function sessionFor(steps) {
  const requests = [];
  const fragments = [];
  return {
    requests, fragments,
    async send(options) {
      const index = requests.length;
      requests.push(plain(options));
      assert.equal(options.headers?.['User-Agent'], BROWSER_UA, '每一步均使用统一浏览器 UA');
      assert.ok(['GET', 'POST'].includes(options.method), '服务协议不得回到统一 HEAD');
      const step = steps[index];
      assert.notEqual(step, undefined, '规则发出了未预期的额外请求');
      const next = typeof step === 'function' ? await step(options, index) : step;
      if (next instanceof Error) { throw next; }
      const reply = { location: '', url: options.url, ...next };
      if (reply.failure === '') {
        if (options.bodyMode === 'none') { reply.body = ''; }
        else if (options.bodyMode === 'small') { reply.body = reply.body.substring(0, 16 * 1024); }
        else if (options.bodyMode === 'html') { reply.body = reply.body.substring(0, 512 * 1024); }
        else if (options.bodyMode === 'scan') { reply.body = scanned(reply.body, options.scanPattern); }
      }
      fragments.push(reply.body);
      return reply;
    }
  };
}
async function check(id, steps, availability, region = '', extra = {}, verify = () => {}) {
  const session = sessionFor(steps);
  const result = await checkService(id, FALLBACK, session);
  assert.deepEqual(plain(result), { availability, region, delay: 37, httpCode: 200, ...extra }, id);
  assert.deepEqual(Object.keys(result).sort(), ['availability', 'delay', 'httpCode', 'region']);
  assert.equal(session.requests.length, steps.length, '必须走完既定协议并在决定性错误处停止');
  for (const secret of ['sensitive-cookie', 'private-refresh', 'device-assertion', 'html-private-marker']) {
    assert.equal(JSON.stringify(result).includes(secret), false, '检测结果不得保留正文或握手令牌');
  }
  await verify(session, result);
  cases++;
}
const only = (url, mode = 'small') => (session) => {
  assert.equal(session.requests[0].url, url);
  assert.equal(session.requests[0].method, 'GET');
  assert.equal(session.requests[0].bodyMode, mode);
};
const chatSteps = (ios = response('Request is not allowed. Please try again later.', 403),
  trace = response('fl=abc\nip=203.0.113.7\nloc=JP\n'), web = response('{}')) => [ios, trace, web];
const disneySteps = (graph = response('{"countryCode":"US","inSupportedLocation":true}'),
  device = response('{"assertion":"device-assertion"}'),
  token = response('{"refresh_token":"private-refresh"}')) => [device, token, graph];
const emptyCdn = () => response('{"targets":[]}');

for (const id of ['google', 'github']) {
  for (const [status, expected] of [[200, 'available'], [204, 'available'], [401, 'restricted'], [403, 'restricted'],
    [429, 'restricted'], [451, 'restricted'], [301, 'unavailable'], [404, 'unavailable'], [405, 'unavailable'], [500, 'unavailable']]) {
    await check(id, [response('html-private-marker', status)], expected, '', { httpCode: status }, only(URLS[id], 'none'));
  }
}
for (const status of [200, 403, 405, 451, 500]) {
  await check('legacy', [response('html-private-marker', status)], 'unknown', '', { httpCode: status }, only(FALLBACK, 'none'));
}

for (const [input, expected] of Object.entries({ US: 'US', jp: 'JP', ' usa ': 'US', CHN: 'CN', HKG: 'HK', MAC: 'MO',
  RUS: 'RU', BLR: 'BY', CUB: 'CU', IRN: 'IR', PRK: 'KP', SYR: 'SY', GBR: 'GB', JPN: 'JP', KOR: 'KR', TWN: 'TW',
  DEU: 'DE', FRA: 'FR', NLD: 'NL', AUS: 'AU', NZL: 'NZ', CAN: 'CA', BRA: 'BR', ZAF: 'ZA', ARE: 'AE', AFG: 'AF',
  ALA: 'AX', ATA: 'AQ', BLM: 'BL', BES: 'BQ', CUW: 'CW', ESH: 'EH', MAF: 'MF', PSE: 'PS', SSD: 'SS',
  SXM: 'SX', TLS: 'TL', UMI: 'UM', ZWE: 'ZW', ZZZ: '', C: '', CNAAA: '', '': '', '1A': '', 'éA': '', 'zh-Hant-TW': '',
  'EU-TTP2': '', ZZ: 'ZZ', XK: 'XK' })) {
  assert.equal(normalizeServiceRegion(input), expected, `地区 ${input}`); cases++;
}
for (const [input, expected] of [['ß', ''], ['ﬀ', ''], ['ſa', 'SA'], ['\u0085 jp \u0085', 'JP'], ['\uFEFFUS', '']]) {
  assert.equal(normalizeServiceRegion(input), expected, '地区规范化遵循 Go 的空白及简单大写语义'); cases++;
}
for (const region of ['AF', 'BY', 'CN', 'CU', 'HK', 'IR', 'KP', 'MO', 'RU', 'SY']) {
  await check('claude', [response(`fl=abc\nloc=${region}\nwarp=off`)], 'unsupported-region', region);
}
await check('claude', [response('loc= jp \n')], 'available', 'JP', {}, only(URLS.claude));
for (const body of ['', 'location=US', 'xloc=US', 'loc=1A', 'loc=zh-Hant-TW']) {
  await check('claude', [response(body)], 'failed');
}
await check('claude', [response('Forbidden', 403)], 'failed', '', { httpCode: 403 });

for (const [body, expected] of [['Request is not allowed. Please try again later.', 'available'],
  ['You may be connected to a disallowed ISP', 'disallowed-isp'], ['Sorry, you have been blocked', 'blocked'],
  ['SORRY, YOU HAVE BEEN BLOCKED', 'blocked'], ['<html>something else entirely</html>', 'failed'], ['', 'failed'],
  ['you may be connected to a disallowed isp; Sorry, you have been blocked', 'disallowed-isp']]) {
  await check('chatgpt', chatSteps(response(body, 403)), expected, 'JP', { httpCode: 403 }, (session) => {
    assert.deepEqual(session.requests.map((request) => request.url), [URLS.chatgpt, URLS.trace, URLS.cookie]);
    assert.ok(session.requests.every((request) => request.bodyMode === 'small'));
  });
}
await check('chatgpt', chatSteps(response('ordinary HTTP 200')), 'failed', 'JP');
await check('chatgpt', chatSteps(response('Sorry, you have been blocked', 403), response('loc=HK\n'),
  response('{"error":"unsupported_country","cookie":"sensitive-cookie"}', 200)), 'unsupported-region', 'HK', { httpCode: 403 });
await check('chatgpt', chatSteps(undefined, failure('timeout'), failure('failed')), 'available', '', { httpCode: 403 });
await check('chatgpt', chatSteps(failure('timeout')), 'timeout', 'JP', { delay: 0, httpCode: 0 });
await check('chatgpt', chatSteps(failure('failed'), response('loc=HK'), response('unsupported_country')),
  'unsupported-region', 'HK', { delay: 0, httpCode: 0 });

for (const [code, region] of [['USA', 'US'], ['JPN', 'JP'], ['HKG', 'HK'], ['CHN', 'CN'], ['RUS', 'RU'],
  ['BLR', 'BY'], ['CUB', 'CU'], ['IRN', 'IR'], ['PRK', 'KP'], ['SYR', 'SY'], ['MAC', 'MO'], ['ZZZ', '']]) {
  const blocked = ['HKG', 'CHN', 'RUS', 'BLR', 'CUB', 'IRN', 'PRK', 'SYR', 'MAC'].includes(code);
  await check('gemini', [response('page,2,1,200,"' + code + 'tail')], blocked ? 'unsupported-region' : 'available', region,
    {}, only(URLS.gemini, 'scan'));
}
for (const body of ['', ',2,1,200,"US', ',2,1,200,"usa', ',2,1,200,"U1A', 'USA']) {
  await check('gemini', [response(body)], 'failed');
}

for (const [body, region] of [['<span id="country-code"> GB </span>', 'GB'],
  ["<span ID='COUNTRY-CODE'> usa </span>", 'US'], ['{"GL":"JP","other":1}', 'JP'],
  ['{"countryCode":"KR"}', 'KR'], ['{"country_code":"BR"}', 'BR']]) {
  await check('youtube', [response(body + 'YouTube Premium')], 'available', region, {}, only(URLS.youtube, 'html'));
}
for (const denied of ['YouTube Premium is not available in your country', 'Premium is not available in your country',
  'Premium is not available in your region']) {
  await check('youtube', [response('ad-free ' + denied + '{"GL":"HK"}')], 'unsupported-region', 'HK');
}
await check('youtube', [response('YouTube Premium', 403)], 'restricted', '', { httpCode: 403 });
await check('youtube', [response('', 500)], 'unavailable', '', { httpCode: 500 });

await check('spotify', [response('{"countryCode":"US"}', 200, { url: 'https://www.spotify.com/de-de/' })],
  'available', 'DE', {}, only(URLS.spotify));
await check('spotify', [response('{"countryCode":"SE"}')], 'available', 'SE');
await check('spotify', [response('{"countryCode":"SE"}', 200, { url: 'https://www.spotify.com/%64%65-de/' })], 'available', 'DE');
await check('spotify', [response('{"countryCode":"SE"}', 200, { url: 'https://www.spotify.com/%QQ/' })], 'available', 'SE');
for (const status of [403, 451]) {
  await check('spotify', [response('{"countryCode":"CN"}', status)], 'unsupported-region', 'CN', { httpCode: status });
}
await check('spotify', [response('NOT AVAILABLE IN YOUR COUNTRY')], 'unsupported-region');
await check('spotify', [response('', 500)], 'unavailable', '', { httpCode: 500 });
await check('spotify', [response('', 401)], 'restricted', '', { httpCode: 401 });

const cluster = '{"idc":"no1a","region":"EU-TTP2","vregion":"EU-TTP2"}';
const tikContext = (region) => `{"webapp.app-context":{"language":"en","region":"${region}","appId":1233}}`;
await check('tiktok', [response(cluster + tikContext('GB'))], 'available', 'GB', {}, only(URLS.tiktok, 'scan'));
await check('tiktok', [response(cluster)], 'available');
await check('tiktok', [response(tikContext('zh-Hant-TW'))], 'available');
await check('tiktok', [response('{"webappXapp-context":{"region":"JP"}}')], 'available');
for (const status of [403, 451]) {
  await check('tiktok', [response('', status)], 'unsupported-region', '', { httpCode: status });
}
await check('tiktok', [response(tikContext('JP'), 500)], 'failed', 'JP', { httpCode: 500 });
for (const denied of ['Access Denied', 'ACCESS DENIED', 'aCcEsS dEnIeD', 'TikTok is not available',
  'TIKTOK IS NOT AVAILABLE', 'not available in your region', 'NOT AVAILABLE IN YOUR REGION']) {
  await check('tiktok', [response(denied + tikContext('US'))], 'unsupported-region', 'US');
  await check('tiktok', [response(tikContext('US') + denied)], 'unsupported-region', 'US');
}
await check('tiktok', [response('"region":"CN"' + tikContext('JP'))], 'available', 'JP');

await check('discord', [response('{"country_code":" jp "}')], 'available', 'JP', {}, only(URLS.discord));
await check('discord', [response('{"country_code":"JP"}', 403)], 'restricted', '', { httpCode: 403 });
await check('discord', [response('', 500)], 'unavailable', '', { httpCode: 500 });
await check('discord', [response('{}')], 'available');

await check('prime-video', [response('{"currentTerritory":"NL"}')], 'available', 'NL', {}, only(URLS['prime-video'], 'scan'));
await check('prime-video', [response('isServiceRestricted:false {"currentTerritory":"US"}')], 'unsupported-region');
await check('prime-video', [response('{"currentTerritory":"US","isServiceRestricted":true}')], 'unsupported-region');
await check('prime-video', [response('ordinary HTTP 200')], 'failed');
await check('prime-video', [response('{"currentTerritory":"zh-Hant-TW"}')], 'available');

await check('bilibili', [response('{"code":0,"result":{"accept_format":"hdf' + 'x'.repeat(18000))],
  'available', 'CN', {}, only(URLS.mainland));
await check('bilibili', [response('{"code":-10403}'), response('{"code":0}', 200, { delay: 83 })],
  'available', '', { delay: 83 }, (session) => assert.deepEqual(session.requests.map((request) => request.url), [URLS.mainland, URLS.hmt]));
await check('bilibili', [response('{"code":-10403}'), response('{"code":-10403}')], 'unsupported-region');
for (const body of ['{"code":-412}', '{"message":"success","result":{"code":0}}', '', '{"code":"0"}']) {
  await check('bilibili', [response(body)], 'failed');
}
await check('bilibili', [response('{"code":-10403}'), failure('timeout')], 'timeout', '', { delay: 0, httpCode: 0 });

await check('netflix', [response('{"targets":[{"location":{"country":"USA"}}]}')], 'available', 'US', {}, (session) => {
  const url = new URL(session.requests[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.fast.com/netflix/speedtest/v2');
  assert.equal(url.searchParams.get('https'), 'true');
  assert.ok((url.searchParams.get('token') ?? '').length > 20, 'CDN 必须携带上游公开客户端 token');
  assert.equal(session.requests[0].bodyMode, 'small');
});
await check('netflix', [response('', 403)], 'blocked', '', { httpCode: 403 });
await check('netflix', [response('{"targets":[null]}')], 'available');
await check('netflix', [response('{"targets":[{"location":{"country":"ZZZ"}}]}')], 'available');
for (const body of ['', '{"targets":[]}', 'null', '[]', '{"targets":"wrong"}',
  '{"targets":[{"location":{"country":1}}]}', '{"targets":[{"location":{"country":"US"}},3]}']) {
  await check('netflix', [response(body), response('', 404), response('', 404)], 'originals-only', '', { httpCode: 404 });
}
await check('netflix', [emptyCdn(), response('', 403), response('', 200)], 'unsupported-region', '', { httpCode: 403 });
await check('netflix', [emptyCdn(), response('', 200), response('', 403)], 'unsupported-region');
await check('netflix', [failure('timeout'), response('', 301, { delay: 61 }), response('', 404),
  response('', 302, { location: 'https://www.netflix.com/gb-en/title/80018499' })], 'available', 'GB',
{ delay: 61, httpCode: 301 }, (session) => {
  assert.deepEqual(session.requests.slice(1).map((request) => request.url), [URLS.title1, URLS.title2, URLS.titleRegion]);
  assert.ok(session.requests.slice(1).every((request) => request.bodyMode === 'none'));
  assert.equal(session.requests[3].noRedirect, true, '地区请求须保留 Location');
});
await check('netflix', [emptyCdn(), response('', 200), response('', 404), failure('failed')], 'available');
await check('netflix', [emptyCdn(), response('', 200), response('', 404), response('', 302, { location: '/jp/title/80018499' })], 'available');
await check('netflix', [emptyCdn(), response('', 429), response('', 500)], 'restricted', '', { httpCode: 429 });
await check('netflix', [emptyCdn(), failure('timeout')], 'timeout', '', { delay: 0, httpCode: 0 });
await check('netflix', [emptyCdn(), response('', 200), failure('failed')], 'failed', '', { delay: 0, httpCode: 0 });

await check('disney-plus', disneySteps(), 'available', 'US', {}, (session) => {
  assert.deepEqual(session.requests.map((request) => request.url), [URLS.devices, URLS.token, URLS.graph]);
  assert.ok(session.requests.every((request) => request.method === 'POST' && request.bodyMode === 'small'));
  for (const request of session.requests) {
    assert.equal(request.headers.Authorization,
      'Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84');
  }
  assert.equal(session.requests[0].headers['Content-Type'], 'application/json; charset=UTF-8');
  assert.deepEqual(JSON.parse(session.requests[0].body), {
    deviceFamily: 'browser', applicationRuntime: 'chrome', deviceProfile: 'windows', attributes: {}
  });
  assert.equal(session.requests[1].headers['Content-Type'], 'application/x-www-form-urlencoded');
  const form = new URLSearchParams(session.requests[1].body);
  assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:token-exchange');
  assert.equal(form.get('subject_token_type'), 'urn:bamtech:params:oauth:token-type:device');
  assert.equal(form.get('subject_token'), 'device-assertion');
  assert.equal(form.get('platform'), 'browser');
  assert.equal(form.get('latitude'), '0'); assert.equal(form.get('longitude'), '0');
  assert.equal(session.requests[2].headers['Content-Type'], 'application/json');
  const graph = JSON.parse(session.requests[2].body);
  assert.equal(graph.variables.input.refreshToken, 'private-refresh');
  assert.equal(graph.query, 'mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }');
});
await check('disney-plus', disneySteps(response('{"countryCode":"GB","inSupportedLocation":false}')), 'coming-soon', 'GB');
await check('disney-plus', disneySteps(response('{"countryCode":"US"}')), 'failed', 'US');
await check('disney-plus', disneySteps(response('{"countryCode":"1A","inSupportedLocation":true}')), 'unavailable');
await check('disney-plus', disneySteps(response('{"inSupportedLocation":true}')), 'unavailable');
await check('disney-plus', [response('', 403)], 'blocked', '', { httpCode: 403 });
for (const body of ['', '{}', '{"assertion":""}', '{"assertion":"\\q"}']) {
  await check('disney-plus', [response(body)], 'failed');
}
for (const body of ['forbidden-location', '403 ERROR']) {
  await check('disney-plus', [disneySteps()[0], response(body)], 'blocked');
}
await check('disney-plus', [disneySteps()[0], response('{}')], 'failed');
await check('disney-plus', [disneySteps()[0], failure('timeout')], 'timeout', '', { delay: 0, httpCode: 0 });
for (const graph of [response(''), response('{"countryCode":"US","inSupportedLocation":true}', 403), failure('timeout')]) {
  await check('disney-plus', disneySteps(graph), 'failed');
}
const assertion = 'device-assertion +&=/%!\'()*"\\\n';
const refresh = 'private-refresh"\\\n\r\t/\u2028';
await check('disney-plus', disneySteps(undefined,
  response(JSON.stringify({ assertion })), response(JSON.stringify({ refresh_token: refresh }))),
'available', 'US', {}, (session) => {
  assert.equal(new URLSearchParams(session.requests[1].body).get('subject_token'), assertion);
  assert.ok(session.requests[1].body.includes('%21%27%28%29%2A'), 'form 必须遵循 Go QueryEscape 的保留字符编码');
  assert.equal(JSON.parse(session.requests[2].body).variables.input.refreshToken, refresh, '刷新令牌必须安全 JSON 转义');
});

// 关键标记跨过 32KiB 边界，并覆盖 Gemini/Prime 的深页位置；实际规则仅收到首个匹配片段。
for (const [id, prefix, marker, expected, region] of [
  ['gemini', 32760, ',2,1,200,"JPN', 'available', 'JP'],
  ['gemini', 850000, ',2,1,200,"HKG', 'unsupported-region', 'HK'],
  ['prime-video', 32760, '"currentTerritory":"NL"', 'available', 'NL'],
  ['prime-video', 4 * 1024 * 1024 + 32760, '"currentTerritory":"US"', 'available', 'US'],
  ['prime-video', 32760, 'isServiceRestricted', 'unsupported-region', ''],
  ['tiktok', 32760, '"webapp.app-context":{"language":"en","region":"GB"', 'available', 'GB'],
  ['tiktok', 32760, 'ACCESS DENIED', 'unsupported-region', '']
]) {
  await check(id, [response('x'.repeat(prefix) + marker + 'html-private-marker')], expected, region, {}, (session) => {
    assert.ok(session.fragments[0].startsWith(marker));
    assert.ok(Buffer.byteLength(session.fragments[0]) <= 32 * 1024 + 256, '证据不得越过单个扫描窗口');
  });
}
await check('gemini', [response('x'.repeat(8 * 1024 * 1024) + ',2,1,200,"USA')], 'failed');
await check('prime-video', [response('x'.repeat(8 * 1024 * 1024) + '"currentTerritory":"US"')], 'failed');
await check('claude', [response('x'.repeat(16 * 1024) + '\nloc=US')], 'failed');
await check('chatgpt', chatSteps(undefined, undefined,
  response('unsupported_country', 0, { failure: 'failed' })), 'available', 'JP', { httpCode: 403 });
await check('claude', [response('loc=US', 0, { failure: 'failed' })], 'failed', '', { delay: 0, httpCode: 0 });

// 所有服务都必须按会话失败事实处理；Netflix/ChatGPT 的上游多步降级语义另有断言。
const ids = ['google', 'github', 'youtube', 'chatgpt', 'claude', 'gemini', 'netflix', 'disney-plus',
  'prime-video', 'spotify', 'tiktok', 'discord', 'bilibili', 'legacy'];
for (const id of ids) {
  for (const kind of ['timeout', 'failed']) {
    const steps = id === 'chatgpt' ? [failure(kind), failure(kind), failure(kind)] :
      id === 'netflix' ? [failure(kind), failure(kind)] : [failure(kind)];
    await check(id, steps, kind, '', { delay: 0, httpCode: 0 });
  }
}

// 致命异常须保留对象身份向上传播，包括每个多步协议的中间及最后请求。
const fatalPaths = ids.map((id) => [id, []]);
fatalPaths.push(['chatgpt', [chatSteps()[0]]], ['chatgpt', chatSteps().slice(0, 2)],
  ['disney-plus', disneySteps().slice(0, 1)], ['disney-plus', disneySteps().slice(0, 2)],
  ['netflix', [emptyCdn()]], ['netflix', [emptyCdn(), response('', 200)]],
  ['netflix', [emptyCdn(), response('', 200), response('', 404)]],
  ['bilibili', [response('{"code":-10403}')]]);
for (const [id, prefix] of fatalPaths) {
  for (const reason of ['cancelled', 'routeChanged', 'capacity', 'controller-protocol']) {
    const fatal = new Error(reason);
    const session = sessionFor([...prefix, fatal]);
    await assert.rejects(checkService(id, FALLBACK, session), (error) => error === fatal,
      `${id} 必须传播 ${reason}`);
    assert.equal(session.requests.length, prefix.length + 1);
    cases++;
  }
}
console.log(`service-rules: ${cases} 项宿主协议用例通过`);
