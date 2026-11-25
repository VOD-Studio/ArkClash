import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// 仅导入纯函数部分校验上下文补全逻辑，不依赖外部 DOM。
const root = fileURLToPath(new URL('../', import.meta.url));
const yamlSource = await readFile(join(root, 'scripts/script-editor/yaml.mjs'), 'utf8');
const stripped = yamlSource
  .replace(/^import\s+\{[^}]+\}\s+from\s+'@codemirror\/language';\s*/m, '')
  .replace(/export const yamlLanguage = StreamLanguage\.define\(\{[\s\S]*?\n\}\);\n/m, '');
const mod = await import(`data:text/javascript;base64,${Buffer.from(stripped, 'utf8').toString('base64')}`);

test('YAML 上下文补全覆盖顶层、DNS、代理、代理组与规则', () => {
  const sample = [
    '# 用户注释必须保留',
    'custom-unknown-field: keep-me',
    'mo',
    'mode: r',
    'dns:',
    '  enh',
    '  enhanced-mode: f',
    '  fallback-filter:',
    '    geo',
    'proxies:',
    '  - name: 香港-01',
    '    type: vl',
    '    real',
    'proxy-groups:',
    '  - name: 代理',
    '    type: url',
    '    proxies:',
    '      - 香',
    'rules:',
    '  - DOMAIN-S',
    '  - DOMAIN-SUFFIX,example.com,代',
    '  - IP-CIDR,1.1.1.1/32,DIRECT,no-',
    '  - MATCH,D',
  ];

  // 顶层键
  const topKey = mod.computeYamlCompletion(sample, 2, 2, false);
  assert.ok(topKey?.options.some(o => o.label === 'mode' && o.apply === 'mode: '));

  // 顶层枚举值
  const topVal = mod.computeYamlCompletion(sample, 3, sample[3].length, false);
  assert.deepEqual(topVal?.options.map(o => o.label), ['rule', 'global', 'direct']);

  // dns 下键与枚举值
  const dnsKey = mod.computeYamlCompletion(sample, 5, sample[5].length, false);
  assert.ok(dnsKey?.options.some(o => o.label === 'enhanced-mode'));
  const dnsVal = mod.computeYamlCompletion(sample, 6, sample[6].length, false);
  assert.deepEqual(dnsVal?.options.map(o => o.label), ['fake-ip', 'redir-host']);

  // dns.fallback-filter 嵌套键
  const ffKey = mod.computeYamlCompletion(sample, 8, sample[8].length, false);
  assert.ok(ffKey?.options.some(o => o.label === 'geoip'));
  assert.ok(ffKey?.options.some(o => o.label === 'geosite'));

  // proxies 列表项键与 type 枚举
  const proxyType = mod.computeYamlCompletion(sample, 11, sample[11].length, false);
  assert.ok(proxyType?.options.some(o => o.label === 'vless'));
  const proxyKey = mod.computeYamlCompletion(sample, 12, sample[12].length, false);
  assert.ok(proxyKey?.options.some(o => o.label === 'reality-opts'));

  // proxy-groups type 枚举与成员动态补全
  const groupType = mod.computeYamlCompletion(sample, 15, sample[15].length, false);
  assert.ok(groupType?.options.some(o => o.label === 'url-test'));
  const groupMember = mod.computeYamlCompletion(sample, 17, sample[17].length, false);
  assert.ok(groupMember?.options.some(o => o.label === '香港-01'));
  assert.ok(groupMember?.options.some(o => o.label === 'DIRECT'));

  // rules 规则类型、动态出口目标、no-resolve 与 MATCH 目标
  const ruleKind = mod.computeYamlCompletion(sample, 19, sample[19].length, false);
  assert.ok(ruleKind?.options.some(o => o.label === 'DOMAIN-SUFFIX' && o.apply === 'DOMAIN-SUFFIX,'));
  const ruleTarget = mod.computeYamlCompletion(sample, 20, sample[20].length, false);
  assert.ok(ruleTarget?.options.some(o => o.label === '代理'));
  assert.ok(ruleTarget?.options.some(o => o.label === '香港-01'));
  assert.ok(ruleTarget?.options.some(o => o.label === 'DIRECT'));
  const ruleFlag = mod.computeYamlCompletion(sample, 21, sample[21].length, false);
  assert.ok(ruleFlag?.options.some(o => o.label === 'no-resolve'));
  const matchTarget = mod.computeYamlCompletion(sample, 22, sample[22].length, false);
  assert.ok(matchTarget?.options.some(o => o.label === 'DIRECT'));
  assert.ok(matchTarget?.options.some(o => o.label === '代理'));
});

test('Tailscale 类型、字段和布尔值按当前代理补全', () => {
  for (const indent of ['', '  ']) {
    const sample = [
      'proxies:',
      indent + '- type: ss',
      indent + '  na',
      indent + '- name: mesh',
      indent + '  aut',
      indent + '  type: "tailscale" # 当前节点',
      indent + '  ephemeral: f',
      indent + '  accept-routes: t',
      indent + '  exit-node-allow-lan-access: f',
      indent + '  auth-key: ',
      indent + '- name: next',
      indent + '  type: ta',
      indent + '  ex',
    ];
    const labels = i => mod.computeYamlCompletion(sample, i, sample[i].length, true)?.options.map(o => o.label);
    const fields = labels(4);
    for (const field of ['name', 'type', 'udp', 'ip-version', 'interface-name', 'routing-mark', 'dialer-proxy',
      'hostname', 'auth-key', 'control-url', 'state-dir', 'ephemeral', 'accept-routes', 'exit-node',
      'exit-node-allow-lan-access']) {
      assert.ok(fields.includes(field), field);
    }
    assert.ok(!fields.includes('server'));
    assert.ok(!labels(2).includes('auth-key'));
    assert.ok(!labels(12).includes('exit-node'));
    assert.ok(labels(11).includes('tailscale'));
    for (const i of [6, 7, 8]) assert.deepEqual(labels(i), ['true', 'false']);
    assert.equal(labels(9), undefined);
  }
});
