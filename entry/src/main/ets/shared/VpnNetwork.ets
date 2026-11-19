export const TUN_IPV4 = '172.19.0.1';
export const TUN_IPV4_DNS = '172.19.0.2';
export const TUN_IPV6 = 'fdfe:dcba:9876::1';
export const TUN_IPV6_DNS = 'fdfe:dcba:9876::2';
export const TUN_STACKS: string[] = ['gvisor', 'system', 'mixed', 'mips'];
export const TUN_CONGESTION_CONTROLLERS: string[] = ['cubic', 'reno', 'bbr', 'bbr3'];
export const MAX_TUN_MTU = 1500;
export const MAX_ROUTE_ENTRIES = 64;

const MAX_VPN_ROUTES = 1024;
const PRIVATE_ROUTES = ['0.0.0.0/8', '10.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
  '192.168.0.0/16', '224.0.0.0/4', '255.255.255.255/32', 'fc00::/7', 'fe80::/10', 'ff00::/8'];

export class VpnNetworkSettings {
  stack: string = 'gvisor';
  ipv6: boolean = false;
  dnsHijacking: boolean = true;
  mtu: number = MAX_TUN_MTU;
  congestionController: string = 'cubic';
  bypassPrivateRoute: boolean = false;
  routeAddress: string[] = [];
  routeExcludeAddress: string[] = [];

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
    return next;
  }
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
