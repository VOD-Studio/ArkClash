import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { newId } from '../shared/profiles/Store';
import { ProfileSettingsFile, readProfileSettings, saveProfileSettings } from './ProfileSettingsFile';

export type DnsOverrideValue = boolean | string | string[];

export interface DnsOverrideSettings {
  revision: string;
  entries: Record<string, DnsOverrideValue>;
}

const DNS_KEYS = ['listen', 'ipv6', 'prefer-h3', 'enhanced-mode', 'fake-ip-filter', 'fake-ip-filter-mode',
  'default-nameserver', 'nameserver', 'fallback', 'proxy-server-nameserver', 'direct-nameserver'];
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

function validEntry(key: string, entry: DnsOverrideValue): boolean {
  if (key === 'ipv6' || key === 'prefer-h3') {
    return typeof entry === 'boolean';
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
  if (!Array.isArray(entry) || entry.length > 256 ||
    (entry.length === 0 && (key === 'nameserver' || key === 'default-nameserver'))) {
    return false;
  }
  return entry.every((line: string): boolean => typeof line === 'string' && line.length > 0 &&
    line.length <= 2048 && line.trim() === line && !/[\x00\r\n]/.test(line) &&
    (key === 'fake-ip-filter' || validDnsServer(line, key === 'default-nameserver')));
}

function checked(settings: DnsOverrideSettings): DnsOverrideSettings {
  if (settings === null || typeof settings !== 'object' || typeof settings.revision !== 'string' ||
    settings.revision === '' || settings.revision.length > 80 || settings.entries === null ||
    typeof settings.entries !== 'object' || Array.isArray(settings.entries)) {
    throw new Error('dns_override_invalid');
  }
  for (const key of Object.keys(settings.entries)) {
    if (!DNS_KEYS.includes(key) || !validEntry(key, settings.entries[key])) {
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
