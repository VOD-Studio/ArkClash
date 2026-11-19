// 字段、选项和枚举来自 FlClash v0.9.3 的 CustomProxyExt。
export type ProxyFieldKind = 'text' | 'secret' | 'number' | 'toggle' | 'choice' | 'list' | 'map';

export class ProxyField {
  id: string;
  path: string[];
  kind: ProxyFieldKind;
  section: string;
  constructor(id: string, path: string[], kind: ProxyFieldKind, section: string) {
    this.id = id;
    this.path = path;
    this.kind = kind;
    this.section = section;
  }
}

export const PROXY_TYPES: string[] = [
  'ss', 'ssr', 'socks5', 'http', 'vmess', 'vless', 'snell', 'trojan',
  'hysteria', 'hysteria2', 'wireguard', 'tuic', 'shadowquic', 'gost-relay', 'direct', 'dns',
  'reject', 'rematch', 'ssh', 'mieru', 'anytls', 'sudoku', 'masque', 'trusttunnel',
  'openvpn', 'tailscale', 'zerotier', 'easytier',
];

export const PROXY_FIELDS: ProxyField[] = [
  new ProxyField('name', ['name'], 'text', 'basic'),
  new ProxyField('server', ['server'], 'text', 'basic'),
  new ProxyField('port', ['port'], 'number', 'basic'),
  new ProxyField('udp', ['udp'], 'toggle', 'basic'),
  new ProxyField('openVpnCa', ['ca'], 'text', 'authentication'),
  new ProxyField('zeroTierNetwork', ['network'], 'text', 'transport'),
  new ProxyField('networkName', ['network-name'], 'text', 'network'),
  new ProxyField('networkSecret', ['network-secret'], 'secret', 'network'),
  new ProxyField('peers', ['peers'], 'list', 'network'),
  new ProxyField('virtualIpv4', ['ipv4'], 'text', 'network'),
  new ProxyField('hostname', ['hostname'], 'text', 'network'),
  new ProxyField('exitNodes', ['exit-nodes'], 'list', 'network'),
  new ProxyField('username', ['username'], 'text', 'authentication'),
  new ProxyField('password', ['password'], 'secret', 'authentication'),
  new ProxyField('uuid', ['uuid'], 'text', 'authentication'),
  new ProxyField('psk', ['psk'], 'secret', 'authentication'),
  new ProxyField('key', ['key'], 'secret', 'authentication'),
  new ProxyField('privateKey', ['private-key'], 'secret', 'authentication'),
  new ProxyField('publicKey', ['public-key'], 'text', 'authentication'),
  new ProxyField('privateKeyPassphrase', ['private-key-passphrase'], 'secret', 'authentication'),
  new ProxyField('preSharedKey', ['pre-shared-key'], 'secret', 'authentication'),
  new ProxyField('authStr', ['auth-str'], 'secret', 'authentication'),
  new ProxyField('cipher', ['cipher'], 'choice', 'other'),
  new ProxyField('alterId', ['alterId'], 'number', 'other'),
  new ProxyField('protocol', ['protocol'], 'choice', 'other'),
  new ProxyField('obfs', ['obfs'], 'choice', 'other'),
  new ProxyField('transport', ['transport'], 'choice', 'other'),
  new ProxyField('up', ['up'], 'text', 'other'),
  new ProxyField('down', ['down'], 'text', 'other'),
  new ProxyField('network', ['network'], 'choice', 'transport'),
  new ProxyField('flow', ['flow'], 'choice', 'transport'),
  new ProxyField('wsPath', ['ws-opts', 'path'], 'text', 'transport'),
  new ProxyField('wsHost', ['ws-opts', 'headers', 'Host'], 'text', 'transport'),
  new ProxyField('wsHeaders', ['ws-opts', 'headers'], 'map', 'transport'),
  new ProxyField('wsMaxEarlyData', ['ws-opts', 'max-early-data'], 'number', 'transport'),
  new ProxyField('wsEarlyDataHeaderName', ['ws-opts', 'early-data-header-name'], 'text', 'transport'),
  new ProxyField('wsHttpUpgrade', ['ws-opts', 'v2ray-http-upgrade'], 'toggle', 'transport'),
  new ProxyField('wsHttpUpgradeFastOpen', ['ws-opts', 'v2ray-http-upgrade-fast-open'], 'toggle', 'transport'),
  new ProxyField('httpMethod', ['http-opts', 'method'], 'text', 'transport'),
  new ProxyField('httpPath', ['http-opts', 'path'], 'list', 'transport'),
  new ProxyField('httpHost', ['http-opts', 'headers', 'Host'], 'list', 'transport'),
  new ProxyField('httpHeaders', ['http-opts', 'headers'], 'map', 'transport'),
  new ProxyField('h2Host', ['h2-opts', 'host'], 'list', 'transport'),
  new ProxyField('h2Path', ['h2-opts', 'path'], 'text', 'transport'),
  new ProxyField('grpcServiceName', ['grpc-opts', 'grpc-service-name'], 'text', 'transport'),
  new ProxyField('xhttpPath', ['xhttp-opts', 'path'], 'text', 'transport'),
  new ProxyField('xhttpHost', ['xhttp-opts', 'host'], 'text', 'transport'),
  new ProxyField('mkcpSeed', ['mkcp-opts', 'seed'], 'secret', 'transport'),
  new ProxyField('mkcpHeader', ['mkcp-opts', 'header'], 'choice', 'transport'),
  new ProxyField('mekyaUrl', ['mekya-opts', 'url'], 'text', 'transport'),
  new ProxyField('headers', ['headers'], 'map', 'other'),
  new ProxyField('tls', ['tls'], 'toggle', 'tls'),
  new ProxyField('sni', ['sni'], 'text', 'tls'),
  new ProxyField('servername', ['servername'], 'text', 'tls'),
  new ProxyField('alpn', ['alpn'], 'list', 'tls'),
  new ProxyField('skipCertVerify', ['skip-cert-verify'], 'toggle', 'tls'),
  new ProxyField('clientFingerprint', ['client-fingerprint'], 'choice', 'tls'),
  new ProxyField('realityPublicKey', ['reality-opts', 'public-key'], 'text', 'tls'),
  new ProxyField('realityShortId', ['reality-opts', 'short-id'], 'text', 'tls'),
  new ProxyField('plugin', ['plugin'], 'choice', 'other'),
  new ProxyField('pluginMode', ['plugin-opts', 'mode'], 'text', 'other'),
  new ProxyField('pluginHost', ['plugin-opts', 'host'], 'text', 'other'),
  new ProxyField('pluginPath', ['plugin-opts', 'path'], 'text', 'other'),
  new ProxyField('pluginUsername', ['plugin-opts', 'username'], 'text', 'other'),
  new ProxyField('pluginPassword', ['plugin-opts', 'password'], 'secret', 'other'),
  new ProxyField('pluginVersion', ['plugin-opts', 'version'], 'number', 'other'),
  new ProxyField('pluginVersionHint', ['plugin-opts', 'version-hint'], 'choice', 'other'),
  new ProxyField('pluginRestlsScript', ['plugin-opts', 'restls-script'], 'text', 'other'),
  new ProxyField('pluginKey', ['plugin-opts', 'key'], 'secret', 'other'),
  new ProxyField('pluginCrypt', ['plugin-opts', 'crypt'], 'choice', 'other'),
  new ProxyField('pluginTls', ['plugin-opts', 'tls'], 'toggle', 'other'),
  new ProxyField('pluginMux', ['plugin-opts', 'mux'], 'toggle', 'other'),
  new ProxyField('pluginSkipCertVerify', ['plugin-opts', 'skip-cert-verify'], 'toggle', 'other'),
  new ProxyField('udpOverTcp', ['udp-over-tcp'], 'toggle', 'other'),
  new ProxyField('protocolParam', ['protocol-param'], 'text', 'other'),
  new ProxyField('obfsParam', ['obfs-param'], 'text', 'other'),
  new ProxyField('obfsPassword', ['obfs-password'], 'secret', 'other'),
  new ProxyField('obfsSecret', ['obfs'], 'secret', 'other'),
  new ProxyField('obfsMode', ['obfs-opts', 'mode'], 'choice', 'other'),
  new ProxyField('obfsHost', ['obfs-opts', 'host'], 'text', 'other'),
  new ProxyField('version', ['version'], 'number', 'other'),
  new ProxyField('ports', ['ports'], 'text', 'other'),
  new ProxyField('hopInterval', ['hop-interval'], 'text', 'other'),
  new ProxyField('congestionController', ['congestion-controller'], 'choice', 'other'),
  new ProxyField('udpRelayMode', ['udp-relay-mode'], 'choice', 'other'),
  new ProxyField('reduceRtt', ['reduce-rtt'], 'toggle', 'other'),
  new ProxyField('ip', ['ip'], 'text', 'other'),
  new ProxyField('ipv6', ['ipv6'], 'text', 'other'),
  new ProxyField('allowedIps', ['allowed-ips'], 'list', 'other'),
  new ProxyField('dns', ['dns'], 'list', 'other'),
  new ProxyField('remoteDnsResolve', ['remote-dns-resolve'], 'toggle', 'other'),
  new ProxyField('mtu', ['mtu'], 'number', 'other'),
  new ProxyField('tfo', ['tfo'], 'toggle', 'connection'),
  new ProxyField('mptcp', ['mptcp'], 'toggle', 'connection'),
  new ProxyField('interfaceName', ['interface-name'], 'text', 'connection'),
  new ProxyField('routingMark', ['routing-mark'], 'number', 'connection'),
  new ProxyField('ipVersion', ['ip-version'], 'choice', 'connection'),
];

export const REQUIRED_PROXY_KEYS: Record<string, string[]> = {
  'ss': ['server', 'port', 'password', 'cipher'],
  'ssr': ['server', 'port', 'password', 'cipher', 'obfs', 'protocol'],
  'vmess': ['server', 'port', 'uuid', 'alterId', 'cipher'],
  'vless': ['server', 'port', 'uuid'],
  'snell': ['server', 'port', 'psk'],
  'trojan': ['server', 'port', 'password'],
  'anytls': ['server', 'port', 'password'],
  'hysteria': ['server', 'up', 'down'],
  'hysteria2': ['server'],
  'wireguard': ['private-key'],
  'ssh': ['server', 'port', 'username'],
  'mieru': ['server', 'transport', 'username', 'password'],
  'sudoku': ['server', 'port', 'key'],
  'masque': ['server', 'port', 'private-key', 'public-key'],
  'openvpn': ['server', 'port', 'ca'],
  'zerotier': ['network'],
  'socks5': ['server', 'port'],
  'http': ['server', 'port'],
  'tuic': ['server', 'port'],
  'shadowquic': ['server', 'port'],
  'gost-relay': ['server', 'port'],
  'trusttunnel': ['server', 'port'],
};

export const PROXY_CREDENTIAL_FIELDS: Record<string, string[]> = {
  'ss': ['cipher', 'password'],
  'ssr': ['cipher', 'protocol', 'obfs', 'password'],
  'vmess': ['cipher', 'alterId', 'uuid'],
  'vless': ['uuid'],
  'tuic': ['uuid', 'password'],
  'trojan': ['password'],
  'anytls': ['password'],
  'hysteria2': ['password'],
  'hysteria': ['up', 'down', 'authStr'],
  'snell': ['psk'],
  'sudoku': ['key'],
  'wireguard': ['privateKey', 'publicKey'],
  'masque': ['privateKey', 'publicKey'],
  'mieru': ['transport', 'username', 'password'],
  'socks5': ['username', 'password'],
  'http': ['username', 'password'],
  'ssh': ['username', 'password'],
  'shadowquic': ['username', 'password'],
  'trusttunnel': ['username', 'password'],
  'gost-relay': ['username', 'password'],
  'openvpn': ['username', 'password', 'openVpnCa'],
  'zerotier': ['zeroTierNetwork'],
  'easytier': ['networkName', 'networkSecret', 'peers', 'virtualIpv4', 'hostname', 'exitNodes'],
};

const TYPE_CHOICES: Record<string, string[]> = {
  'cipher:ss': ['aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305', 'xchacha20-ietf-poly1305', '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305', 'aes-128-ctr', 'aes-192-ctr', 'aes-256-ctr', 'aes-128-cfb', 'aes-192-cfb', 'aes-256-cfb', 'rc4-md5', 'chacha20-ietf', 'xchacha20', 'chacha20', 'none'],
  'cipher:ssr': ['aes-128-ctr', 'aes-192-ctr', 'aes-256-ctr', 'aes-128-cfb', 'aes-192-cfb', 'aes-256-cfb', 'rc4-md5', 'chacha20-ietf', 'xchacha20', 'chacha20', 'none'],
  'cipher:vmess': ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'aes-128-cfb', 'none', 'zero'],
  'protocol:ssr': ['origin', 'auth_sha1_v4', 'auth_aes128_md5', 'auth_aes128_sha1', 'auth_chain_a', 'auth_chain_b'],
  'protocol:hysteria': ['udp', 'wechat-video', 'faketcp'],
  'obfs:ssr': ['plain', 'http_simple', 'http_post', 'random_head', 'tls1.2_ticket_auth', 'tls1.2_ticket_fastauth'],
  'obfs:hysteria2': ['salamander', 'gecko'],
  'network:vmess': ['tcp', 'ws', 'http', 'h2', 'grpc', 'mekya', 'mkcp'],
  'network:vless': ['tcp', 'ws', 'http', 'h2', 'grpc', 'xhttp'],
  'network:trojan': ['tcp', 'ws', 'grpc'],
};

const COMMON_CHOICES: Record<string, string[]> = {
  'transport': ['TCP', 'UDP'],
  'flow': ['xtls-rprx-vision'],
  'clientFingerprint': ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'chrome120', 'firefox120', 'safari16', 'none'],
  'plugin': ['obfs', 'v2ray-plugin', 'gost-plugin', 'shadow-tls', 'restls', 'jls', 'kcptun'],
  'pluginVersionHint': ['tls13', 'tls12'],
  'pluginCrypt': ['aes', 'aes-128', 'aes-192', 'aes-128-gcm', 'salsa20', 'blowfish', 'twofish', 'cast5', '3des', 'tea', 'xtea', 'xor', 'none', 'null'],
  'mkcpHeader': ['none', 'srtp', 'utp', 'wechat-video', 'dtls', 'wireguard'],
  'obfsMode': ['http', 'tls', 'shadow-tls', 'restls', 'jls'],
  'congestionController': ['cubic', 'new_reno', 'bbr', 'bbr_meta_v1', 'bbr_meta_v2'],
  'udpRelayMode': ['native', 'quic'],
  'ipVersion': ['dual', 'ipv4', 'ipv6', 'ipv4-prefer', 'ipv6-prefer'],
};

export function proxyChoices(type: string, id: string): string[] {
  return TYPE_CHOICES[`${id}:${type}`] ?? COMMON_CHOICES[id] ?? [];
}

const OPTION_TYPES: Record<string, string[]> = {
  'privateKey': ['ssh'],
  'privateKeyPassphrase': ['ssh'],
  'preSharedKey': ['wireguard'],
  'allowedIps': ['wireguard'],
  'obfs': ['hysteria2'],
  'obfsPassword': ['hysteria2'],
  'up': ['hysteria2'],
  'down': ['hysteria2'],
  'protocol': ['hysteria'],
  'obfsSecret': ['hysteria'],
  'flow': ['vless'],
  'headers': ['http'],
  'tls': ['socks5', 'http', 'vmess', 'vless', 'gost-relay'],
  'sni': ['http', 'trojan', 'hysteria', 'hysteria2', 'tuic', 'shadowquic', 'gost-relay', 'anytls', 'masque', 'trusttunnel'],
  'servername': ['vmess', 'vless'],
  'alpn': ['vmess', 'vless', 'trojan', 'hysteria', 'hysteria2', 'tuic', 'shadowquic', 'anytls', 'trusttunnel'],
  'skipCertVerify': ['socks5', 'http', 'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2',
    'tuic', 'gost-relay', 'anytls', 'masque', 'trusttunnel'],
  'clientFingerprint': ['ss', 'vmess', 'vless', 'snell', 'trojan', 'gost-relay', 'anytls', 'trusttunnel'],
  'realityPublicKey': ['vmess', 'vless', 'trojan'],
  'realityShortId': ['vmess', 'vless', 'trojan'],
  'plugin': ['ss'],
  'udpOverTcp': ['ss'],
  'protocolParam': ['ssr'],
  'obfsParam': ['ssr'],
  'obfsMode': ['snell'],
  'obfsHost': ['snell'],
  'version': ['snell'],
  'ports': ['hysteria', 'hysteria2'],
  'hopInterval': ['hysteria', 'hysteria2'],
  'congestionController': ['tuic', 'shadowquic', 'masque', 'trusttunnel'],
  'udpRelayMode': ['tuic'],
  'reduceRtt': ['tuic'],
  'ip': ['wireguard', 'masque'],
  'ipv6': ['wireguard', 'masque'],
  'dns': ['wireguard', 'masque'],
  'remoteDnsResolve': ['wireguard', 'masque'],
  'mtu': ['wireguard', 'masque'],
};

const TRANSPORT_FIELDS: Record<string, string[]> = {
  'ws': ['wsPath', 'wsHost', 'wsHeaders', 'wsMaxEarlyData', 'wsEarlyDataHeaderName', 'wsHttpUpgrade',
    'wsHttpUpgradeFastOpen'],
  'http': ['httpMethod', 'httpPath', 'httpHost', 'httpHeaders'],
  'h2': ['h2Host', 'h2Path'],
  'grpc': ['grpcServiceName'],
  'xhttp': ['xhttpPath', 'xhttpHost'],
  'mkcp': ['mkcpSeed', 'mkcpHeader'],
  'mekya': ['mekyaUrl'],
};

const PLUGIN_FIELDS: Record<string, string[]> = {
  'obfs': ['pluginMode', 'pluginHost'],
  'v2ray-plugin': ['pluginMode', 'pluginHost', 'pluginPath', 'pluginTls', 'pluginMux', 'pluginSkipCertVerify'],
  'gost-plugin': ['pluginMode', 'pluginHost', 'pluginPath', 'pluginTls', 'pluginMux', 'pluginSkipCertVerify'],
  'kcptun': ['pluginMode', 'pluginKey', 'pluginCrypt'],
  'shadow-tls': ['pluginHost', 'pluginPassword', 'pluginVersion', 'pluginSkipCertVerify'],
  'restls': ['pluginHost', 'pluginPassword', 'pluginVersionHint', 'pluginRestlsScript', 'pluginSkipCertVerify'],
  'jls': ['pluginHost', 'pluginUsername', 'pluginPassword'],
};

const NO_SOCKET_OPTIONS = ['dns', 'reject', 'rematch'];
const NO_TCP_OPTIONS = NO_SOCKET_OPTIONS.concat(
  ['hysteria', 'hysteria2', 'tuic', 'wireguard', 'shadowquic', 'masque', 'tailscale', 'zerotier', 'easytier']);

export type ProxyDefinition = Record<string, Object | undefined>;

export function proxyMap(value: Object | undefined): ProxyDefinition | undefined {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value) ?
    value as ProxyDefinition : undefined;
}

export function proxyKey(object: ProxyDefinition, key: string): string {
  return Object.keys(object).find((candidate: string): boolean => candidate.toLowerCase() === key.toLowerCase()) ?? key;
}

export function proxyValue(definition: ProxyDefinition, path: string[]): Object | undefined {
  let value: Object | undefined = definition;
  for (const key of path) {
    const mapping = proxyMap(value);
    if (mapping === undefined) { return undefined; }
    value = mapping[proxyKey(mapping, key)];
  }
  return value === null ? undefined : value;
}

export function proxyText(definition: ProxyDefinition, path: string[]): string {
  return String(proxyValue(definition, path) ?? '');
}

export function copyProxyKey(key: string): boolean {
  return key !== '__proto__' && key !== 'constructor' && key !== 'prototype';
}

export function withProxyValue(definition: ProxyDefinition, path: string[], value: Object | undefined): ProxyDefinition {
  const key = proxyKey(definition, path[0]);
  const result: ProxyDefinition = {};
  for (const name of Object.keys(definition)) {
    if (name !== key && copyProxyKey(name)) { result[name] = definition[name]; }
  }
  const child = path.length === 1 ? value :
    withProxyValue(proxyMap(definition[key]) ?? {}, path.slice(1), value);
  const map = proxyMap(child);
  if (child !== undefined && child !== '' && (map === undefined || Object.keys(map).length > 0)) {
    result[key] = child;
  }
  return result;
}

export function proxyOptions(definition: ProxyDefinition): ProxyField[] {
  const type = proxyText(definition, ['type']);
  const network = proxyText(definition, ['network']);
  const validTransport = proxyChoices(type, 'network').includes(network);
  const plugin = proxyText(definition, ['plugin']);
  const credentialIds = PROXY_CREDENTIAL_FIELDS[type] ?? [];
  return PROXY_FIELDS.filter((field: ProxyField): boolean => {
    const id = field.id;
    if (credentialIds.includes(id)) { return false; }
    if (id === 'network') { return proxyChoices(type, id).length > 0; }
    if (id === 'tfo' || id === 'mptcp') { return !NO_TCP_OPTIONS.includes(type); }
    if (field.section === 'connection') { return !NO_SOCKET_OPTIONS.includes(type); }
    if (id === 'obfsPassword' && proxyValue(definition, ['obfs']) === undefined) { return false; }
    if (id === 'wsHttpUpgradeFastOpen' && proxyValue(definition, ['ws-opts', 'v2ray-http-upgrade']) !== true) {
      return false;
    }
    return (OPTION_TYPES[id]?.includes(type) ?? false) ||
      (validTransport && (TRANSPORT_FIELDS[network]?.includes(id) ?? false)) ||
      (type === 'ss' && (PLUGIN_FIELDS[plugin]?.includes(id) ?? false));
  });
}

export function changeProxyOption(definition: ProxyDefinition, field: ProxyField, value: Object | undefined): ProxyDefinition {
  let next = withProxyValue(definition, field.path, value);
  if (field.id !== 'network' && field.id !== 'plugin' && field.id !== 'obfs' && field.id !== 'wsHttpUpgrade') {
    return next;
  }
  const after = proxyOptions(next);
  for (const option of proxyOptions(definition)) {
    if (!after.includes(option) && proxyValue(next, option.path) !== undefined) {
      next = withProxyValue(next, option.path, undefined);
    }
  }
  return next;
}

export function changeProxyType(definition: ProxyDefinition, type: string): ProxyDefinition {
  const oldType = proxyText(definition, ['type']);
  if (type === oldType) { return definition; }
  const oldCredentialIds = PROXY_CREDENTIAL_FIELDS[oldType] ?? [];
  const newCredentialIds = PROXY_CREDENTIAL_FIELDS[type] ?? [];
  const oldOptions = proxyOptions(definition);
  let next = withProxyValue(definition, ['type'], type);
  for (const field of PROXY_FIELDS) {
    const offered = oldCredentialIds.includes(field.id) || oldOptions.includes(field);
    if (!offered || proxyValue(next, field.path) === undefined) { continue; }
    const choices = proxyChoices(type, field.id);
    const oldChoices = proxyChoices(oldType, field.id);
    const belongs = newCredentialIds.includes(field.id) || proxyOptions(next).includes(field);
    if (!belongs || (choices.join(',') !== oldChoices.join(',') &&
      !choices.includes(proxyText(next, field.path)))) {
      next = changeProxyOption(next, field, undefined);
    }
  }
  if (type === 'vmess') {
    if (proxyValue(next, ['cipher']) === undefined) { next = withProxyValue(next, ['cipher'], 'auto'); }
    if (proxyValue(next, ['alterId']) === undefined) { next = withProxyValue(next, ['alterId'], 0); }
  }
  if (type === 'mieru' && proxyValue(next, ['transport']) === undefined) {
    next = withProxyValue(next, ['transport'], 'TCP');
  }
  return next;
}

export function proxyList(definition: ProxyDefinition, path: string[]): string[] {
  const value = proxyValue(definition, path);
  if (Array.isArray(value)) { return (value as Object[]).map((item: Object): string => String(item)); }
  return value === undefined || value === '' ? [] : [String(value)];
}

function mapValueText(value: Object | undefined): string {
  return Array.isArray(value) ? (value as Object[]).join(', ') : String(value ?? '');
}

export function proxyFieldHasValue(definition: ProxyDefinition, field: ProxyField): boolean {
  const value = proxyValue(definition, field.path);
  if (field.kind !== 'map') { return value !== undefined; }
  const mapping: ProxyDefinition = proxyMap(value) ?? {};
  return Object.keys(mapping).some((key: string): boolean =>
    field.id === 'headers' || key.toLowerCase() !== 'host');
}

export function proxyMapText(definition: ProxyDefinition, field: ProxyField): string {
  const previous = proxyMap(proxyValue(definition, field.path)) ?? {};
  return Object.keys(previous).filter((key: string): boolean =>
    field.id !== 'headers' ? key.toLowerCase() !== 'host' : true).map((key: string): string =>
    `${key}: ${mapValueText(previous[key])}`).join('\n');
}

export function parseProxyMap(definition: ProxyDefinition, field: ProxyField, text: string): ProxyDefinition {
  const previous = proxyMap(proxyValue(definition, field.path)) ?? {};
  const result: ProxyDefinition = {};
  const keys = new Set<string>();
  const ownsHost = field.id !== 'headers';
  if (ownsHost) {
    const host = proxyKey(previous, 'Host');
    if (previous[host] !== undefined) { result[host] = previous[host]; }
  }
  for (const line of text.split('\n')) {
    if (line.trim() === '') { continue; }
    const separator = line.indexOf(':');
    const key = line.slice(0, separator).trim();
    const lower = key.toLowerCase();
    if (separator < 1 || key === '' || !copyProxyKey(key) || keys.has(lower) || (ownsHost && lower === 'host')) {
      throw new Error('local_proxy_map');
    }
    keys.add(lower);
    const value = line.slice(separator + 1).trim();
    const old = previous[proxyKey(previous, key)];
    result[key] = old !== undefined && value === mapValueText(old) ? old : field.id === 'httpHeaders' ? [value] : value;
  }
  return result;
}
