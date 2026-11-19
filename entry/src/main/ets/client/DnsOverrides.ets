import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { newId } from '../shared/profiles/Store';
import { ProfileSettingsFile, readProfileSettings, saveProfileSettings } from './ProfileSettingsFile';

export interface DnsPolicyRow {
  pattern: string;
  servers: string[];
}

export type DnsOverrideValue = boolean | number | string | string[] | DnsPolicyRow[];

export interface DnsOverrideSettings {
  revision: string;
  entries: Record<string, DnsOverrideValue>;
}

const DNS_TOGGLES = ['ipv6', 'use-hosts', 'use-system-hosts', 'respect-rules', 'prefer-h3', 'fallback-lazy-query',
  'direct-nameserver-follow-policy', 'fallback-filter.geoip'];
const DNS_NUMBERS = ['ipv6-timeout', 'cache-max-size', 'fake-ip-ttl'];
const DNS_SERVER_LISTS = ['default-nameserver', 'nameserver', 'fallback', 'proxy-server-nameserver', 'direct-nameserver'];
const DNS_MATCH_LISTS = ['fake-ip-filter', 'fallback-filter.geosite', 'fallback-filter.ipcidr', 'fallback-filter.domain'];
const SCHEMES = ['udp', 'tcp', 'tls', 'http', 'https', 'quic', 'ts', 'tailscale', 'et', 'easytier', 'dhcp', 'rcode'];

export function emptyDnsOverrides(): DnsOverrideSettings {
  return { revision: 'default', entries: {} };
}

function ipv4Literal(host: string): boolean {
  const words = host.split('.');
  return words.length === 4 && words.every((word: string): boolean => /^\d{1,3}$/.test(word) && Number(word) <= 255);
}

function validDnsServer(text: string, bootstrap: boolean): boolean {
  if (text === 'system' || text === 'dhcp://system' || /^system:\/\/(?:[#?].*)?$/.test(text)) {
    return true;
  }
  const schemeEnd = text.indexOf('://');
  const scheme = schemeEnd < 0 ? 'udp' : text.slice(0, schemeEnd);
  if (!SCHEMES.includes(scheme)) {
    return false;
  }
  const endpoint = schemeEnd < 0 ? text : text.slice(schemeEnd + 3);
  const authority = endpoint.split(/[/?#]/, 1)[0];
  const host = schemeEnd < 0 && !authority.startsWith('[') && authority.split(':').length > 2 ?
    `[${authority}]` : authority;
  try {
    const parsed = url.URL.parseURL(`http://${host}`);
    if (parsed.hostname === '') {
      return false;
    }
    if (scheme === 'rcode') {
      return ['success', 'format_error', 'server_failure', 'name_error', 'not_implemented', 'refused']
        .includes(parsed.hostname) && !bootstrap;
    }
    return !bootstrap || parsed.hostname.startsWith('[') || ipv4Literal(authority.split(':')[0]);
  } catch (_error) {
    return false;
  }
}

function validListen(text: string): boolean {
  if (text === '') {
    return true;
  }
  const match = /^([^:\s/?#@]*|\[[0-9a-fA-F:.]+\]):(\d{1,5})$/.exec(text);
  if (match === null || text.length > 320 || Number(match[2]) < 1 || Number(match[2]) > 65535) {
    return false;
  }
  try {
    return match[1] === '' || url.URL.parseURL(`http://${match[1]}`).hostname !== '';
  } catch (_error) {
    return false;
  }
}

function validItem(text: string, limit: number = 2048): boolean {
  return typeof text === 'string' && text.length > 0 && text.length <= limit && text.trim() === text &&
    !/[\x00\r\n]/.test(text);
}

function validPrefix(text: string, family: number = 0, pool: boolean = false): boolean {
  const sides = text.split('/');
  if (sides.length !== 2 || !/^(0|[1-9]\d{0,2})$/.test(sides[1])) { return false; }
  const host = sides[0];
  const length = Number(sides[1]);
  if (host.includes(':')) {
    if (family === 4 || length > (pool ? 125 : 128) || !/^[0-9a-f:.]+$/i.test(host)) { return false; }
    try {
      const address = url.URL.parseURL(`http://[${host}]`).hostname;
      return address.startsWith('[') && (!pool || !/^\[::ffff:[0-9a-f]+:[0-9a-f]+\]$/i.test(address));
    } catch (_error) {
      return false;
    }
  }
  return family !== 6 && length <= (pool ? 29 : 32) && ipv4Literal(host) &&
    host.split('.').every((part: string): boolean => /^(0|[1-9]\d{0,2})$/.test(part));
}

function validPolicy(rows: DnsPolicyRow[]): boolean {
  if (rows.length > 256) { return false; }
  const seen = new Set<string>();
  for (const row of rows) {
    if (row === null || typeof row !== 'object' || !validItem(row.pattern) || seen.has(row.pattern) ||
      !Array.isArray(row.servers) || row.servers.length === 0 || row.servers.length > 256 ||
      !row.servers.every((server: string): boolean => validItem(server) && validDnsServer(server, false))) {
      return false;
    }
    seen.add(row.pattern);
  }
  return true;
}

export function dnsPolicyText(rows: DnsPolicyRow[]): string {
  const lines: string[] = [];
  for (const row of rows) {
    for (const server of row.servers) { lines.push(`${row.pattern} = ${server}`); }
  }
  return lines.join('\n');
}

export function parseDnsPolicyText(text: string): DnsPolicyRow[] {
  const rows: DnsPolicyRow[] = [];
  const groups = new Map<string, DnsPolicyRow>();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '') { continue; }
    const separator = line.indexOf('=');
    const pattern = line.slice(0, separator).trim();
    const server = line.slice(separator + 1).trim();
    if (separator <= 0 || pattern === '' || server === '') { throw new Error('dns_override_invalid'); }
    const row = groups.get(pattern);
    if (row === undefined) {
      const added: DnsPolicyRow = { pattern: pattern, servers: [server] };
      groups.set(pattern, added);
      rows.push(added);
    } else {
      row.servers.push(server);
    }
  }
  if (!validPolicy(rows)) { throw new Error('dns_override_invalid'); }
  return rows;
}

function validEntry(key: string, entry: DnsOverrideValue): boolean {
  if (DNS_TOGGLES.includes(key)) {
    return typeof entry === 'boolean';
  }
  if (DNS_NUMBERS.includes(key)) {
    return typeof entry === 'number' && Number.isInteger(entry) && entry >= 0 && entry <= 2147483647;
  }
  if (key === 'listen') {
    return typeof entry === 'string' && validListen(entry);
  }
  if (key === 'enhanced-mode') {
    return typeof entry === 'string' && ['normal', 'fake-ip', 'redir-host'].includes(entry);
  }
  if (key === 'fake-ip-filter-mode') {
    return typeof entry === 'string' && ['blacklist', 'whitelist', 'rule'].includes(entry);
  }
  if (key === 'cache-algorithm') { return entry === 'arc' || entry === 'lru'; }
  if (key === 'fake-ip-range' || key === 'fake-ip-range6') {
    return typeof entry === 'string' && (entry === '' || validPrefix(entry, key === 'fake-ip-range' ? 4 : 6, true));
  }
  if (key === 'fallback-filter.geoip-code') {
    return typeof entry === 'string' && validItem(entry, 64);
  }
  if (key === 'nameserver-policy' || key === 'proxy-server-nameserver-policy') {
    return Array.isArray(entry) && validPolicy(entry as DnsPolicyRow[]);
  }
  if (!DNS_SERVER_LISTS.includes(key) && !DNS_MATCH_LISTS.includes(key)) { return false; }
  if (!Array.isArray(entry) || entry.length > 256 ||
    (entry.length === 0 && (key === 'nameserver' || key === 'default-nameserver'))) {
    return false;
  }
  return (entry as string[]).every((line: string): boolean => validItem(line) &&
    (DNS_SERVER_LISTS.includes(key) ? validDnsServer(line, key === 'default-nameserver') :
      key !== 'fallback-filter.ipcidr' || validPrefix(line)));
}

function checked(settings: DnsOverrideSettings): DnsOverrideSettings {
  if (settings === null || typeof settings !== 'object' || typeof settings.revision !== 'string' ||
    settings.revision === '' || settings.revision.length > 80 || settings.entries === null ||
    typeof settings.entries !== 'object' || Array.isArray(settings.entries)) {
    throw new Error('dns_override_invalid');
  }
  for (const key of Object.keys(settings.entries)) {
    if (!validEntry(key, settings.entries[key])) {
      throw new Error('dns_override_invalid');
    }
  }
  return settings;
}

const storage: ProfileSettingsFile<DnsOverrideSettings> = {
  fileName: 'dns-overrides.json', endpoint: '/arkclash/dns/settings', errorPrefix: 'dns_override',
  defaults: emptyDnsOverrides, checked: checked
};

export function readDnsOverrides(filesDir: string): Promise<DnsOverrideSettings> {
  return readProfileSettings<DnsOverrideSettings>(filesDir, storage);
}

export function saveDnsOverrides(context: common.UIAbilityContext, expectedRevision: string,
  entries: Record<string, DnsOverrideValue>): Promise<DnsOverrideSettings> {
  return saveProfileSettings<DnsOverrideSettings>(context, storage, expectedRevision,
    { revision: newId('dns.'), entries: entries });
}
