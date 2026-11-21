import { stringify } from 'yaml';
import { nameImportedProxies } from './LocalProxies';
import { ProxyDefinition, proxyText } from './LocalProxySchema';

const SHARE_SCHEMES: string[] = ['ss', 'ssr', 'vmess', 'vless', 'trojan', 'tuic', 'hysteria', 'hysteria2',
  'hy2', 'hysteria2+realm', 'hy2+realm', 'socks', 'socks5', 'socks5h', 'anytls', 'mierus'];

export function isProxyShareLink(source: string): boolean {
  const separator = source.indexOf('://');
  return separator > 0 && SHARE_SCHEMES.includes(source.substring(0, separator).toLowerCase()) &&
    source.substring(separator + 3).trim() !== '';
}

interface ShareProfileGroup {
  name: string;
  type: string;
  proxies: string[];
}

interface ShareProfileConfig {
  proxies: ProxyDefinition[];
  'proxy-groups': ShareProfileGroup[];
  rules: string[];
}

export interface ShareProfileSource {
  definitions: ProxyDefinition[];
  name: string;
  yaml: string;
}

export function buildShareProfile(definitions: ProxyDefinition[]): ShareProfileSource {
  const group = 'PROXY';
  const proxies = nameImportedProxies(definitions, group);
  const names = proxies.map((proxy: ProxyDefinition): string => proxyText(proxy, ['name']));
  const config: ShareProfileConfig = { proxies: proxies,
    'proxy-groups': [{ name: group, type: 'select', proxies: names }], rules: [`MATCH,${group}`] };
  return { definitions: proxies, name: names[0] ?? '', yaml: stringify(config) };
}
