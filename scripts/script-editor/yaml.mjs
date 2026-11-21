import { StreamLanguage } from '@codemirror/language';

// 面向 mihomo YAML 配置的轻量高亮器：按行扫描，编辑大配置时不构建整棵语法树。
const YAML_BOOL_OR_NULL = /^(?:true|false|yes|no|on|off|null|~)(?=\s*(?:#.*)?$|[\],}])/i;
const YAML_NUMBER = /^(?:[-+]?(?:0x[0-9a-fA-F]+|0o[0-7]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?))(?=\s*(?:#.*)?$|[\],}])/;
const YAML_KEY = /^(?:[^:#\[\]{},\s][^:#\[\]{},]*?)(?=\s*:(?:\s|$))/;

export const yamlLanguage = StreamLanguage.define({
  name: 'yaml',
  startState() {
    return { blockIndent: -1, afterColon: false };
  },
  token(stream, state) {
    if (stream.sol()) {
      state.afterColon = false;
      const indent = stream.indentation();
      if (state.blockIndent >= 0) {
        if (stream.match(/^\s*$/)) return null;
        if (indent > state.blockIndent) {
          stream.skipToEnd();
          return 'string';
        }
        state.blockIndent = -1;
      }
      if (stream.match(/^(?:---|\.\.\.)(?=\s|$)/)) return 'meta';
    }

    if (stream.eatSpace()) return null;

    const ch = stream.peek();
    if (ch === '#') {
      stream.skipToEnd();
      return 'comment';
    }

    if (ch === '"' || ch === "'") {
      const quote = stream.next();
      while (!stream.eol()) {
        const next = stream.next();
        if (quote === '"' && next === '\\') {
          stream.next();
        } else if (next === quote) {
          if (quote === "'" && stream.peek() === "'") {
            stream.next();
          } else {
            break;
          }
        }
      }
      if (!state.afterColon && stream.match(/^\s*(?=:(\s|$))/, false)) {
        return 'propertyName';
      }
      return 'string';
    }

    if (ch === '&' || ch === '*') {
      if (stream.match(/^[&*][^\s,\[\]{}]+/)) return 'meta';
    }
    if (ch === '!') {
      if (stream.match(/^![^\s,\[\]{}]*/)) return 'meta';
    }

    if (state.afterColon && (ch === '|' || ch === '>')) {
      if (stream.match(/^[|>][+-]?\d*(?=\s*(?:#.*)?$)/)) {
        state.blockIndent = stream.indentation();
        return 'operator';
      }
    }

    if (ch === '-' && stream.match(/^-(?=\s|$)/)) {
      return 'punctuation';
    }
    if (ch === ':' && stream.match(/^:(?=\s|$)/)) {
      state.afterColon = true;
      return 'punctuation';
    }
    if (ch === '[' || ch === ']' || ch === '{' || ch === '}' || ch === ',') {
      stream.next();
      return 'punctuation';
    }

    if (!state.afterColon && stream.match(YAML_KEY)) {
      return 'propertyName';
    }

    if (stream.match(YAML_BOOL_OR_NULL)) return 'atom';
    if (stream.match(YAML_NUMBER)) return 'number';

    stream.match(/^[^#\[\]{},:\s]+/) || stream.next();
    return state.afterColon ? 'string' : null;
  },
  languageData: {
    commentTokens: { line: '#' },
  },
});

const TOP_LEVEL_KEYS = [
  'mode', 'port', 'socks-port', 'redir-port', 'tproxy-port', 'mixed-port',
  'allow-lan', 'bind-address', 'log-level', 'ipv6', 'unified-delay', 'tcp-concurrent',
  'global-client-fingerprint', 'global-ua', 'etag-support',
  'keep-alive-idle', 'keep-alive-interval', 'disable-keep-alive',
  'find-process-mode', 'external-controller', 'secret',
  'geodata-mode', 'geodata-loader', 'geosite-matcher', 'geox-url',
  'geo-auto-update', 'geo-update-interval',
  'profile', 'dns', 'sniffer', 'tun', 'ntp', 'hosts', 'tls', 'experimental',
  'proxies', 'proxy-groups', 'proxy-providers', 'rule-providers', 'rules', 'sub-rules',
  'listeners', 'tunnels', 'authentication', 'skip-auth-prefixes',
  'lan-allowed-ips', 'lan-disallowed-ips',
];

const SECTION_KEYS = {
  '': TOP_LEVEL_KEYS,
  dns: [
    'enable', 'listen', 'ipv6', 'ipv6-timeout', 'prefer-h3', 'use-hosts', 'use-system-hosts',
    'respect-rules', 'enhanced-mode', 'fake-ip-range', 'fake-ip-range6',
    'fake-ip-filter', 'fake-ip-filter-mode', 'fake-ip-ttl',
    'default-nameserver', 'nameserver', 'nameserver-policy',
    'fallback', 'fallback-filter', 'fallback-lazy-query',
    'proxy-server-nameserver', 'proxy-server-nameserver-policy',
    'direct-nameserver', 'direct-nameserver-follow-policy',
    'cache-algorithm', 'cache-max-size',
  ],
  'dns.fallback-filter': ['geoip', 'geoip-code', 'geosite', 'ipcidr', 'domain'],
  'proxies.*': [
    'name', 'type', 'server', 'port', 'udp', 'tfo', 'mptcp', 'ip-version',
    'dialer-proxy', 'interface-name', 'routing-mark', 'smux',
    'tls', 'sni', 'servername', 'skip-cert-verify', 'client-fingerprint', 'fingerprint', 'alpn',
    'network', 'ws-opts', 'grpc-opts', 'h2-opts', 'http-opts', 'reality-opts',
    'cipher', 'password', 'uuid', 'alterId', 'flow', 'packet-encoding',
    'plugin', 'plugin-opts', 'auth', 'up', 'down', 'obfs', 'obfs-password',
    'congestion-controller', 'udp-relay-mode', 'username',
    'private-key', 'public-key', 'pre-shared-key', 'ip', 'ipv6', 'mtu', 'reserved',
  ],
  'proxies.*.ws-opts': ['path', 'headers', 'max-early-data', 'early-data-header-name', 'v2ray-http-upgrade'],
  'proxies.*.grpc-opts': ['grpc-service-name'],
  'proxies.*.reality-opts': ['public-key', 'short-id'],
  'proxy-groups.*': [
    'name', 'type', 'proxies', 'use', 'url', 'interval', 'timeout', 'lazy',
    'tolerance', 'strategy', 'max-failed-times', 'expected-status',
    'include-all', 'include-all-proxies', 'include-all-providers',
    'filter', 'exclude-filter', 'exclude-type', 'hidden', 'icon', 'disable-udp',
  ],
  'proxy-providers.*': [
    'type', 'url', 'path', 'interval', 'filter', 'exclude-filter', 'exclude-type',
    'dialer-proxy', 'proxy', 'size-limit', 'header', 'health-check', 'override',
  ],
  'proxy-providers.*.health-check': ['enable', 'url', 'interval', 'timeout', 'lazy', 'expected-status'],
  'rule-providers.*': ['type', 'behavior', 'format', 'url', 'path', 'interval', 'proxy', 'size-limit', 'header'],
  sniffer: [
    'enable', 'force-dns-mapping', 'parse-pure-ip', 'override-destination',
    'sniff', 'force-domain', 'skip-domain', 'skip-src-address', 'skip-dst-address', 'port-whitelist',
  ],
  tun: [
    'enable', 'stack', 'device', 'dns-hijack', 'auto-route', 'auto-redirect',
    'auto-detect-interface', 'mtu', 'strict-route', 'endpoint-independent-nat',
    'udp-timeout', 'congestion-controller',
  ],
  ntp: ['enable', 'server', 'port', 'interval', 'dialer-proxy', 'write-to-system'],
  profile: ['store-selected', 'store-fake-ip'],
  'geox-url': ['geoip', 'geosite', 'mmdb', 'asn'],
  experimental: ['quic-go-disable-gso', 'quic-go-disable-ecn', 'dialer-ip4p-convert', 'fingerprints'],
  tls: ['certificate', 'private-key', 'client-auth-type', 'client-auth-cert', 'ech-key', 'custom-certifactes'],
};

const BOOLEAN_KEYS = new Set([
  'enable', 'allow-lan', 'ipv6', 'udp', 'tls', 'tfo', 'mptcp', 'skip-cert-verify',
  'unified-delay', 'tcp-concurrent', 'hidden', 'lazy', 'include-all',
  'include-all-proxies', 'include-all-providers', 'store-selected', 'store-fake-ip',
  'use-hosts', 'use-system-hosts', 'respect-rules', 'prefer-h3', 'geoip',
  'geo-auto-update', 'geodata-mode', 'override-destination', 'force-dns-mapping',
  'parse-pure-ip', 'disable-udp', 'disable-keep-alive', 'etag-support',
  'strict-route', 'auto-route', 'auto-redirect', 'auto-detect-interface',
  'fallback-lazy-query', 'direct-nameserver-follow-policy', 'write-to-system',
]);

const VALUE_ENUMS = {
  mode: ['rule', 'global', 'direct'],
  'log-level': ['silent', 'error', 'warning', 'info', 'debug'],
  'find-process-mode': ['off', 'strict', 'always'],
  'enhanced-mode': ['fake-ip', 'redir-host'],
  'fake-ip-filter-mode': ['blacklist', 'whitelist', 'rule'],
  'cache-algorithm': ['lru', 'arc'],
  'geodata-loader': ['standard', 'memconservative'],
  'geosite-matcher': ['succinct', 'mph'],
  stack: ['gvisor', 'system', 'mixed'],
  network: ['ws', 'grpc', 'h2', 'http', 'tcp'],
  strategy: ['consistent-hashing', 'round-robin', 'sticky-sessions'],
  behavior: ['domain', 'ipcidr', 'classical'],
  format: ['yaml', 'text', 'mrs'],
  'client-fingerprint': ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized'],
  'global-client-fingerprint': ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized'],
  'ip-version': ['dual', 'ipv4', 'ipv6', 'ipv4-prefer', 'ipv6-prefer'],
  'congestion-controller': ['cubic', 'bbr', 'new_reno'],
};

const CONTEXT_VALUE_ENUMS = {
  'proxies.*.type': [
    'ss', 'ssr', 'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2',
    'tuic', 'anytls', 'wireguard', 'http', 'socks5', 'ssh', 'snell', 'mieru', 'direct',
  ],
  'proxy-groups.*.type': ['select', 'url-test', 'fallback', 'load-balance', 'relay'],
  'proxy-providers.*.type': ['http', 'file', 'inline'],
  'rule-providers.*.type': ['http', 'file', 'inline'],
};

const RULE_TYPES = [
  'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-WILDCARD', 'DOMAIN-REGEX',
  'GEOSITE', 'GEOIP', 'IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN',
  'SRC-IP-CIDR', 'SRC-PORT', 'DST-PORT', 'IN-PORT', 'IN-TYPE', 'NETWORK',
  'RULE-SET', 'SUB-RULE', 'AND', 'OR', 'NOT', 'MATCH',
];

const BUILTIN_TARGETS = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL'];
const RULE_FLAGS = ['no-resolve', 'src'];

const DYNAMIC_SECTION_PARENTS = new Set(['proxies', 'proxy-groups', 'proxy-providers', 'rule-providers', 'sub-rules']);

function leadingSpaces(text) {
  let i = 0;
  while (i < text.length && text[i] === ' ') i++;
  return i;
}

function parseMappingKey(trimmed) {
  const match = /^(['"]?)([A-Za-z0-9_.-]+)\1\s*:/.exec(trimmed);
  return match ? match[2] : null;
}

export function resolveYamlPath(lines, lineIndex, effectiveIndent) {
  const chain = [];
  let minIndent = effectiveIndent;
  const stopAt = Math.max(0, lineIndex - 300);
  for (let i = lineIndex - 1; i >= stopAt && minIndent > 0; i--) {
    const raw = lines[i];
    const trimmed = raw.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const indent = leadingSpaces(raw);
    if (indent >= minIndent) continue;
    if (trimmed.startsWith('-')) {
      const rest = trimmed.slice(1).trim();
      const dashKey = parseMappingKey(rest);
      const itemIndent = indent + 2;
      if (dashKey && itemIndent < effectiveIndent && rest.endsWith(':')) {
        chain.push({ key: dashKey, isListItem: false });
      }
      chain.push({ key: '*', isListItem: true });
      minIndent = indent;
      continue;
    }
    const key = parseMappingKey(trimmed);
    if (key) {
      chain.push({ key, isListItem: false });
      minIndent = indent;
    }
  }
  chain.reverse();
  const normalized = [];
  for (let i = 0; i < chain.length; i++) {
    const seg = chain[i].key;
    const parent = normalized[normalized.length - 1];
    if (seg === '*' && (parent === 'proxies' || parent === 'proxy-groups')) {
      normalized.push('*');
    } else if (seg !== '*' && DYNAMIC_SECTION_PARENTS.has(parent)) {
      normalized.push('*');
    } else if (seg !== '*') {
      normalized.push(seg);
    }
  }
  return normalized;
}

export function collectDocumentOutbounds(lines) {
  const names = [];
  const seen = new Set(BUILTIN_TARGETS);
  let section = '';
  const limit = Math.min(lines.length, 4000);
  for (let i = 0; i < limit && names.length < 200; i++) {
    const raw = lines[i];
    if (!raw || raw[0] === '#') continue;
    const indent = leadingSpaces(raw);
    const trimmed = raw.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    if (indent === 0) {
      const key = parseMappingKey(trimmed);
      section = key === 'proxy-groups' || key === 'proxies' ? key : '';
      continue;
    }
    if (!section) continue;
    const match = /^(?:-\s+)?name\s*:\s*(.+)$/.exec(trimmed);
    if (!match) continue;
    let value = match[1].replace(/\s+#.*$/, '').trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (value && !seen.has(value)) {
      seen.add(value);
      names.push(value);
    }
  }
  return names;
}

function getLines(doc) {
  if (Array.isArray(doc)) return doc;
  const result = [];
  for (let i = 1; i <= doc.lines; i++) result.push(doc.line(i).text);
  return result;
}

export function computeYamlCompletion(lines, lineIndex, column, explicit) {
  const lineText = lines[lineIndex] ?? '';
  const before = lineText.slice(0, column);
  const after = lineText.slice(column);
  if (/^\s*#/.test(before)) return null;

  const indent = leadingSpaces(lineText);
  const trimmedBefore = before.trimStart();

  // 规则列表项（rules / sub-rules.<name>）
  const listMatch = /^(\s*)-\s*(.*)$/.exec(before);
  if (listMatch) {
    const itemIndent = listMatch[1].length + 2;
    const content = listMatch[2];
    const path = resolveYamlPath(lines, lineIndex, itemIndent);
    const keyPath = path.join('.');

    // `- name: ...` 这类映射项中的键或值
    const inlineColon = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(content);
    if (inlineColon) {
      const itemPath = path.length === 1 && (path[0] === 'proxies' || path[0] === 'proxy-groups')
        ? `${path[0]}.*` : keyPath;
      return completeValue(itemPath, inlineColon[1], inlineColon[2], column, lines, explicit);
    }

    if (keyPath === 'rules' || keyPath === 'sub-rules.*') {
      return completeRuleItem(content, column, lines, explicit);
    }

    if (keyPath === 'proxy-groups.*.proxies') {
      const token = /[^\s,]*$/.exec(content)?.[0] ?? '';
      if (!token && !explicit) return null;
      const targets = [...BUILTIN_TARGETS, ...collectDocumentOutbounds(lines)];
      return {
        from: column - token.length,
        options: targets.map(label => ({ label, type: 'variable' })),
        validFor: /^[^\s,]*$/,
      };
    }

    const itemKeyPath = path.length === 1 && (path[0] === 'proxies' || path[0] === 'proxy-groups')
      ? `${path[0]}.*` : keyPath;
    if (SECTION_KEYS[itemKeyPath]) {
      return completeKey(itemKeyPath, content, after, column, explicit);
    }
    return null;
  }

  // 普通 `key: value` 行
  const colonMatch = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(trimmedBefore);
  if (colonMatch) {
    const path = resolveYamlPath(lines, lineIndex, indent);
    return completeValue(path.join('.'), colonMatch[1], colonMatch[2], column, lines, explicit);
  }

  // 键名位置
  if (/^[A-Za-z0-9_.-]*$/.test(trimmedBefore)) {
    const path = resolveYamlPath(lines, lineIndex, indent);
    return completeKey(path.join('.'), trimmedBefore, after, column, explicit);
  }
  return null;
}

function completeKey(pathKey, prefix, after, column, explicit) {
  const keys = SECTION_KEYS[pathKey];
  if (!keys || (!prefix && !explicit)) return null;
  const hasColon = /^\s*:/.test(after);
  return {
    from: column - prefix.length,
    options: keys.map(key => ({
      label: key,
      type: 'property',
      apply: hasColon ? key : `${key}: `,
    })),
    validFor: /^[A-Za-z0-9_.-]*$/,
  };
}

function completeValue(pathKey, key, rawValue, column, lines, explicit) {
  const token = /[A-Za-z0-9_.-]*$/.exec(rawValue)?.[0] ?? '';
  if (!token && !explicit) return null;
  const scoped = CONTEXT_VALUE_ENUMS[`${pathKey}.${key}`];
  let values = scoped ?? VALUE_ENUMS[key];
  if (!values && BOOLEAN_KEYS.has(key)) values = ['true', 'false'];
  if (!values && key === 'dialer-proxy') {
    values = collectDocumentOutbounds(lines);
  }
  if (!values || values.length === 0) return null;
  return {
    from: column - token.length,
    options: values.map(label => ({ label, type: 'enum' })),
    validFor: /^[A-Za-z0-9_.-]*$/,
  };
}

function completeRuleItem(content, column, lines, explicit) {
  const stripped = content.replace(/^['"]/, '');
  const parts = stripped.split(',');
  const current = parts[parts.length - 1];
  const token = current.trimStart();
  if (!token && !explicit) return null;
  const from = column - token.length;

  if (parts.length === 1) {
    return {
      from,
      options: RULE_TYPES.map(label => ({ label, type: 'keyword', apply: `${label},` })),
      validFor: /^[A-Za-z0-9-]*$/,
    };
  }
  const ruleKind = parts[0].trim().toUpperCase();
  const targetIndex = ruleKind === 'MATCH' ? 1 : 2;
  if (parts.length - 1 === targetIndex) {
    const targets = [...BUILTIN_TARGETS, ...collectDocumentOutbounds(lines)];
    return {
      from,
      options: targets.map(label => ({ label, type: 'variable' })),
      validFor: /^[^,\s]*$/,
    };
  }
  if (parts.length - 1 > targetIndex) {
    return {
      from,
      options: RULE_FLAGS.map(label => ({ label, type: 'keyword' })),
      validFor: /^[A-Za-z-]*$/,
    };
  }
  return null;
}

export function completeMihomoYaml(context) {
  const line = context.state.doc.lineAt(context.pos);
  const lines = getLines(context.state.doc);
  const result = computeYamlCompletion(lines, line.number - 1, context.pos - line.from, context.explicit);
  if (!result) return null;
  return {
    from: line.from + result.from,
    options: result.options,
    validFor: result.validFor,
  };
}
