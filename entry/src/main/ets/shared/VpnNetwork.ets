export const TUN_IPV4 = '172.19.0.1';
export const TUN_IPV4_DNS = '172.19.0.2';
export const TUN_IPV6 = 'fdfe:dcba:9876::1';
export const TUN_IPV6_DNS = 'fdfe:dcba:9876::2';
export const TUN_STACKS: string[] = ['gvisor', 'system', 'mixed', 'mips'];
export const TUN_CONGESTION_CONTROLLERS: string[] = ['cubic', 'reno', 'bbr', 'bbr3'];
export const MAX_TUN_MTU = 1500;
export const MAX_ROUTE_ENTRIES = 64;
// API 23 起系统名单上限 256：黑名单本应用占 1 个名额，白名单不含本应用。
export const MAX_VPN_EXCLUDED_APPS = 255;
export const MAX_VPN_TRUSTED_APPS = 256;

export type VpnAppAccessMode = 'off' | 'blocked' | 'trusted';
export const VPN_APP_ACCESS_MODES: VpnAppAccessMode[] = ['off', 'blocked', 'trusted'];

const MAX_VPN_ROUTES = 1024;
const PRIVATE_ROUTES = ['0.0.0.0/8', '10.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
  '192.168.0.0/16', '224.0.0.0/4', '255.255.255.255/32', 'fc00::/7', 'fe80::/10', 'ff00::/8'];
const BM_DUMP_HEADER = /^(?:ID|userId)\s*:\s*\d+:?$/i;

export interface VpnNetworkSnapshot {
  stack?: string;
  ipv6?: boolean;
  dnsHijacking?: boolean;
  mtu?: number;
  congestionController?: string;
  bypassPrivateRoute?: boolean;
  routeAddress?: string[];
  routeExcludeAddress?: string[];
  appAccessMode?: string;
  excludedApplications?: string[];
  trustedApplications?: string[];
}

export interface BundleImportResult {
  valid: string[];
  invalid: string[];
  skippedOwn: boolean;
}

export class VpnNetworkSettings implements VpnNetworkSnapshot {
  stack: string = 'gvisor';
  ipv6: boolean = false;
  dnsHijacking: boolean = true;
  mtu: number = MAX_TUN_MTU;
  congestionController: string = 'cubic';
  bypassPrivateRoute: boolean = false;
  routeAddress: string[] = [];
  routeExcludeAddress: string[] = [];
  appAccessMode: VpnAppAccessMode = 'off';
  excludedApplications: string[] = [];
  trustedApplications: string[] = [];

  copy(): VpnNetworkSettings {
    const next = new VpnNetworkSettings();
    next.stack = this.stack;
    next.ipv6 = this.ipv6;
    next.dnsHijacking = this.dnsHijacking;
    next.mtu = this.mtu;
    next.congestionController = this.congestionController;
    next.bypassPrivateRoute = this.bypassPrivateRoute;
    next.routeAddress = this.routeAddress.slice();
    next.routeExcludeAddress = this.routeExcludeAddress.slice();
    next.appAccessMode = this.appAccessMode;
    next.excludedApplications = this.excludedApplications.slice();
    next.trustedApplications = this.trustedApplications.slice();
    return next;
  }
}

export function isValidBundleName(name: string): boolean {
  if (typeof name !== 'string' || name.length < 7 || name.length > 128 || !/^[a-z]/i.test(name)) {
    return false;
  }
  const segments = name.split('.');
  return segments.length >= 3 &&
    segments.every((segment: string): boolean => /^[a-z0-9](?:[a-z0-9_]*[a-z0-9])?$/i.test(segment));
}

export function vpnApplicationList(apps: string[] | undefined, own: string, limit: number): string[] {
  if (apps !== undefined && !Array.isArray(apps)) { throw new Error('invalid_bundle_name'); }
  const entries = new Set<string>();
  for (const name of apps ?? []) {
    if (name === own) { continue; }
    if (!isValidBundleName(name)) {
      throw new Error('invalid_bundle_name');
    }
    entries.add(name);
  }
  if (entries.size > limit) { throw new Error('too_many_apps'); }
  return Array.from(entries);
}

export function vpnExcludedApplications(apps: string[] | undefined, own: string): string[] {
  return vpnApplicationList(apps, own, MAX_VPN_EXCLUDED_APPS);
}

export function vpnTrustedApplications(apps: string[] | undefined, own: string): string[] {
  return vpnApplicationList(apps, own, MAX_VPN_TRUSTED_APPS);
}

export function inferAppAccessMode(mode: string | undefined, excluded: string[]): VpnAppAccessMode {
  if (mode === undefined || mode === '') {
    return excluded.length > 0 ? 'blocked' : 'off';
  }
  if (mode === 'off' || mode === 'blocked' || mode === 'trusted') {
    return mode;
  }
  throw new Error('invalid_option');
}

export function normalizeVpnNetworkSettings(raw: VpnNetworkSnapshot | undefined, own: string,
  strict: boolean = false): VpnNetworkSettings {
  const settings = new VpnNetworkSettings();
  if (raw === undefined) {
    return settings;
  }
  settings.stack = raw.stack ?? settings.stack;
  settings.ipv6 = raw.ipv6 ?? settings.ipv6;
  settings.dnsHijacking = raw.dnsHijacking ?? settings.dnsHijacking;
  settings.mtu = raw.mtu ?? settings.mtu;
  settings.congestionController = raw.congestionController ?? settings.congestionController;
  settings.bypassPrivateRoute = raw.bypassPrivateRoute ?? settings.bypassPrivateRoute;
  settings.routeAddress = Array.isArray(raw.routeAddress) ? raw.routeAddress.slice() : [];
  settings.routeExcludeAddress = Array.isArray(raw.routeExcludeAddress) ? raw.routeExcludeAddress.slice() : [];
  settings.excludedApplications = vpnExcludedApplications(raw.excludedApplications, own);
  settings.trustedApplications = vpnTrustedApplications(raw.trustedApplications, own);
  settings.appAccessMode = inferAppAccessMode(raw.appAccessMode, settings.excludedApplications);
  if (strict) {
    if (!Number.isInteger(settings.mtu) || settings.mtu < minTunMtu(settings.ipv6) || settings.mtu > MAX_TUN_MTU) {
      throw new Error('invalid_mtu');
    }
    if (!TUN_STACKS.includes(settings.stack) || !TUN_CONGESTION_CONTROLLERS.includes(settings.congestionController)) {
      throw new Error('invalid_option');
    }
    if (settings.appAccessMode === 'trusted' && settings.trustedApplications.length === 0) {
      throw new Error('empty_trusted_apps');
    }
    vpnRoutePrefixes(settings);
  }
  return settings;
}

function sameStringSet(left: string[], right: string[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  const set = new Set<string>(left);
  return set.size === right.length && right.every((entry: string): boolean => set.has(entry));
}

/** 仅比较当前生效的分应用模式与对应名单；调整未启用名单不触发重连提示。 */
export function vpnAccessEffectiveEqual(previous: VpnNetworkSettings, next: VpnNetworkSettings): boolean {
  if (previous.appAccessMode !== next.appAccessMode) {
    return false;
  }
  if (next.appAccessMode === 'blocked') {
    return sameStringSet(previous.excludedApplications, next.excludedApplications);
  }
  if (next.appAccessMode === 'trusted') {
    return sameStringSet(previous.trustedApplications, next.trustedApplications);
  }
  return true;
}

/** 解析多行包名或 hdc shell bm dump -a 输出，自动去重、跳过自身包名并收集非法项。 */
export function parseBundleImportText(raw: string, own: string): BundleImportResult {
  const valid = new Set<string>();
  const invalid = new Set<string>();
  let skippedOwn = false;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#') || trimmed.startsWith('//') || BM_DUMP_HEADER.test(trimmed)) {
      continue;
    }
    for (const part of trimmed.split(/[\s,;，；]+/)) {
      const token = part.replace(/^["'`]+|["'`]+$/g, '');
      if (token === '') {
        continue;
      }
      if (token === own) {
        skippedOwn = true;
        continue;
      }
      if (isValidBundleName(token)) {
        valid.add(token);
      } else {
        invalid.add(token);
      }
    }
  }
  return { valid: Array.from(valid), invalid: Array.from(invalid), skippedOwn: skippedOwn };
}

export function minTunMtu(ipv6: boolean): number {
  return ipv6 ? 1280 : 576;
}

export class VpnRoutePrefix {
  readonly address: string;
  readonly length: number;
  readonly ipv6: boolean;

  constructor(address: string, length: number, ipv6: boolean) {
    this.address = address;
    this.length = length;
    this.ipv6 = ipv6;
  }
}

function ipv4Bits(address: string): string {
  const parts = address.split('.');
  if (parts.length !== 4 || parts.some((part: string): boolean =>
    !/^(0|[1-9][0-9]{0,2})$/.test(part) || Number(part) > 255)) {
    throw new Error('invalid_cidr');
  }
  return parts.map((part: string): string => Number(part).toString(2).padStart(8, '0')).join('');
}

function ipv6Bits(address: string): string {
  if (address.includes('.')) {
    const lastColon = address.lastIndexOf(':');
    const tail = ipv4Bits(address.slice(lastColon + 1));
    address = address.slice(0, lastColon + 1) + parseInt(tail.slice(0, 16), 2).toString(16) + ':' +
      parseInt(tail.slice(16), 2).toString(16);
  }
  const sides = address.split('::');
  const left = sides[0] === '' ? [] : sides[0].split(':');
  const right = sides.length === 2 && sides[1] !== '' ? sides[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if (sides.length > 2 || (sides.length === 1 ? missing !== 0 : missing < 1)) {
    throw new Error('invalid_cidr');
  }
  const words = left.concat(new Array<string>(missing).fill('0'), right);
  if (words.some((word: string): boolean => !/^[\da-fA-F]{1,4}$/.test(word))) {
    throw new Error('invalid_cidr');
  }
  return words.map((word: string): string => parseInt(word, 16).toString(2).padStart(16, '0')).join('');
}

function parsePrefixes(entries: string[], ipv6: boolean): string[] {
  return entries.filter((entry: string): boolean => entry.includes(':') === ipv6)
    .map((entry: string): string => {
      const parts = entry.split('/');
      const length = Number(parts[1]);
      if (entry.length > 49 || parts.length !== 2 || !/^(0|[1-9][0-9]{0,2})$/.test(parts[1]) ||
        length > (ipv6 ? 128 : 32)) {
        throw new Error('invalid_cidr');
      }
      return (ipv6 ? ipv6Bits(parts[0]) : ipv4Bits(parts[0])).slice(0, length);
    });
}

function subtractRoutes(included: string[], excluded: string[]): string[] {
  let routes: string[] = [];
  for (const prefix of included.sort()) {
    if (!routes.some((existing: string): boolean => prefix.startsWith(existing))) {
      routes.push(prefix);
    }
  }
  for (const exclusion of excluded.sort()) {
    const remaining: string[] = [];
    for (const route of routes) {
      if (route.startsWith(exclusion)) {
        continue;
      }
      if (!exclusion.startsWith(route)) {
        remaining.push(route);
        continue;
      }
      for (let bit = route.length; bit < exclusion.length; bit++) {
        remaining.push(exclusion.slice(0, bit) + (exclusion[bit] === '0' ? '1' : '0'));
      }
    }
    if (remaining.length > MAX_VPN_ROUTES) {
      throw new Error('too_many_routes');
    }
    routes = remaining;
  }
  return routes;
}

function routesForFamily(included: string[], excluded: string[], ipv6: boolean): VpnRoutePrefix[] {
  const routes = subtractRoutes(included, excluded);
  const dns = ipv6 ? ipv6Bits(TUN_IPV6_DNS) : ipv4Bits(TUN_IPV4_DNS);
  // 私有网段及用户排除项也可能覆盖内置 DNS，需保留该地址的主机路由。
  if (!routes.some((route: string): boolean => dns.startsWith(route))) {
    routes.push(dns);
  }
  const size = ipv6 ? 128 : 32;
  const wordSize = ipv6 ? 16 : 8;
  return routes.map((route: string): VpnRoutePrefix => {
    const bits = route.padEnd(size, '0');
    const words: string[] = [];
    for (let offset = 0; offset < size; offset += wordSize) {
      words.push(parseInt(bits.slice(offset, offset + wordSize), 2).toString(ipv6 ? 16 : 10));
    }
    return new VpnRoutePrefix(words.join(ipv6 ? ':' : '.'), route.length, ipv6);
  });
}

export function vpnRoutePrefixes(settings: VpnNetworkSettings): VpnRoutePrefix[] {
  if (settings.routeAddress.length > MAX_ROUTE_ENTRIES || settings.routeExcludeAddress.length > MAX_ROUTE_ENTRIES) {
    throw new Error('too_many_entries');
  }
  const exclude = settings.bypassPrivateRoute ?
    settings.routeExcludeAddress.concat(PRIVATE_ROUTES) : settings.routeExcludeAddress;
  const allRoutes = settings.routeAddress.length === 0;
  const ipv4 = routesForFamily(allRoutes ? [''] : parsePrefixes(settings.routeAddress, false),
    parsePrefixes(exclude, false), false);
  const ipv6Includes = parsePrefixes(settings.routeAddress, true);
  const ipv6Excludes = parsePrefixes(exclude, true);
  const routes = settings.ipv6 ? ipv4.concat(routesForFamily(allRoutes ? [''] : ipv6Includes, ipv6Excludes, true)) : ipv4;
  if (routes.length > MAX_VPN_ROUTES) {
    throw new Error('too_many_routes');
  }
  return routes;
}
