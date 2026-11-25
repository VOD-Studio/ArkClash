import { Document, isMap, ToJSOptions } from 'yaml';
import { ProfileYamlMapping, readProfileYaml } from './ProfileYamlFields';

export type CustomNetworkSection = 'ntp' | 'sniffer';
export type CustomNetworkValues = Record<string, string>;
export type CustomNetworkChanges = Record<string, string | null>;

type CustomNetworkKind = 'toggle' | 'protocol' | 'text' | 'port' | 'interval' | 'list' | 'ports';

export class CustomNetworkField {
  readonly key: string;
  readonly kind: CustomNetworkKind;

  constructor(key: string, kind: CustomNetworkKind) {
    this.key = key;
    this.kind = kind;
  }
}

const CUSTOM_SNIFF_PROTOCOLS: string[] = ['HTTP', 'TLS', 'QUIC'];
const NETWORK_YAML_INPUT: ToJSOptions = { maxAliasCount: 100 };
const NTP_FIELDS: CustomNetworkField[] = [new CustomNetworkField('enable', 'toggle'),
  new CustomNetworkField('server', 'text'), new CustomNetworkField('port', 'port'),
  new CustomNetworkField('interval', 'interval'), new CustomNetworkField('dialer-proxy', 'text'),
  new CustomNetworkField('write-to-system', 'toggle')];
const SNIFFER_FIELDS: CustomNetworkField[] = [new CustomNetworkField('enable', 'toggle'),
  new CustomNetworkField('override-destination', 'toggle'), new CustomNetworkField('force-dns-mapping', 'toggle'),
  new CustomNetworkField('parse-pure-ip', 'toggle'), new CustomNetworkField('force-domain', 'list'),
  new CustomNetworkField('skip-domain', 'list'), new CustomNetworkField('skip-src-address', 'list'),
  new CustomNetworkField('skip-dst-address', 'list')];

for (const protocol of CUSTOM_SNIFF_PROTOCOLS) {
  const key = 'sniff.' + protocol;
  SNIFFER_FIELDS.push(new CustomNetworkField(key, 'protocol'), new CustomNetworkField(key + '.ports', 'ports'),
    new CustomNetworkField(key + '.override-destination', 'toggle'));
}

export function customNetworkFields(section: CustomNetworkSection): CustomNetworkField[] {
  return section === 'ntp' ? NTP_FIELDS : SNIFFER_FIELDS;
}

type CustomNetworkMapping = Record<string, Object | undefined>;

function asMapping(input: Object | undefined): CustomNetworkMapping {
  if (input === undefined || input === null) { return {}; }
  if (typeof input !== 'object' || Array.isArray(input)) { throw new Error('custom_shape'); }
  return input as CustomNetworkMapping;
}

function resolvedSection(document: Document<ProfileYamlMapping>, section: CustomNetworkSection): CustomNetworkMapping {
  return asMapping(asMapping(document.toJS(NETWORK_YAML_INPUT) as Object)[section]);
}

function protocolKey(sniff: CustomNetworkMapping, protocol: string): string {
  return Object.keys(sniff).find((key: string): boolean => key.toUpperCase() === protocol) ?? protocol;
}

function legacyProtocols(raw: CustomNetworkMapping): CustomNetworkMapping {
  if (Object.keys(asMapping(raw['sniff'])).length > 0 || !Array.isArray(raw['sniffing'])) { return {}; }
  const entries: CustomNetworkMapping = {};
  for (const protocol of raw['sniffing'] as Object[]) {
    const key = String(protocol).toUpperCase();
    if (!CUSTOM_SNIFF_PROTOCOLS.includes(key)) { throw new Error('custom_shape'); }
    const config: CustomNetworkMapping = {};
    const ports = raw['port-whitelist'];
    if (Array.isArray(ports)) { config['ports'] = (ports as Object[]).slice(); }
    entries[key] = config;
  }
  return entries;
}

export function readCustomNetworkOptions(source: string, section: CustomNetworkSection): CustomNetworkValues {
  const raw = resolvedSection(readProfileYaml(source, 'invalid_yaml'), section);
  const empty: CustomNetworkMapping = {};
  const legacy = section === 'sniffer' ? legacyProtocols(raw) : empty;
  const sniff = Object.keys(legacy).length > 0 ? legacy : asMapping(raw['sniff']);
  const values: CustomNetworkValues = {};
  for (const field of customNetworkFields(section)) {
    const path = field.key.split('.');
    const protocol = path.length > 1 ? sniff[protocolKey(sniff, path[1])] : undefined;
    const current = path.length === 1 ? raw[field.key] :
      path.length === 2 ? protocol : asMapping(protocol)[path[2]];
    if (current === undefined || current === null) { continue; }
    if (field.kind === 'protocol') { values[field.key] = 'true'; }
    else if (Array.isArray(current)) { values[field.key] = (current as Object[]).join('\n'); }
    else { values[field.key] = String(current); }
  }
  return values;
}

function portRange(entry: string): boolean {
  const match = /^(\d{1,5})(?:-(\d{1,5}))?$/.exec(entry);
  return match !== null && Number(match[1]) >= 1 && Number(match[2] ?? match[1]) >= Number(match[1]) &&
    Number(match[2] ?? match[1]) <= 65535;
}

function networkValue(kind: CustomNetworkKind, text: string): Object {
  if (kind === 'toggle') {
    if (text === 'true' || text === 'false') { return text === 'true'; }
    throw new Error('custom_network_invalid');
  }
  if (kind === 'port' || kind === 'interval') {
    const number = Number(text);
    const max = kind === 'port' ? 65535 : 2147483647;
    if (!/^\d+$/.test(text) || number < 1 || number > max) { throw new Error('custom_network_invalid'); }
    return number;
  }
  if (kind === 'list' || kind === 'ports') {
    const lines = text.split('\n').map((line: string): string => line.trim())
      .filter((line: string): boolean => line !== '');
    if (kind === 'ports' && !lines.every(portRange)) { throw new Error('custom_network_invalid'); }
    return lines;
  }
  return text.trim();
}

export function editableNetworkMapping(document: Document<ProfileYamlMapping>, path: string[],
  resolved: CustomNetworkMapping): ProfileYamlMapping {
  const node = document.getIn(path, true) as Object | undefined;
  if (isMap(node) && !(node as ProfileYamlMapping).has('<<')) { return node as ProfileYamlMapping; }
  const mapping = document.createNode(resolved) as ProfileYamlMapping;
  if (isMap(node)) { mapping.anchor = (node as ProfileYamlMapping).anchor; }
  document.setIn(path, mapping);
  return mapping;
}

export function applyCustomNetworkOptions(document: Document<ProfileYamlMapping>, section: CustomNetworkSection,
  changes: CustomNetworkChanges): void {
  const keys = Object.keys(changes);
  if (keys.length === 0) { return; }
  const raw = resolvedSection(document, section);
  const root = editableNetworkMapping(document, [section], raw);
  const editsProtocols = section === 'sniffer' && keys.some((key: string): boolean => key.startsWith('sniff.'));
  if (editsProtocols) {
    const legacy = legacyProtocols(raw);
    if (Object.keys(legacy).length > 0) {
      root.set('sniff', legacy);
      root.delete('sniffing');
      root.delete('port-whitelist');
      raw['sniff'] = legacy;
    }
  }
  for (const field of customNetworkFields(section)) {
    if (!keys.includes(field.key)) { continue; }
    const value = changes[field.key];
    const path = field.key.split('.');
    if (path.length === 1) {
      if (value === null) { root.delete(field.key); } else { root.set(field.key, networkValue(field.kind, value)); }
      continue;
    }
    const sniff = asMapping(raw['sniff']);
    const key = protocolKey(sniff, path[1]);
    const protocols = editableNetworkMapping(document, [section, 'sniff'], sniff);
    if (field.kind === 'protocol') {
      if (value === 'true' && !protocols.has(key)) {
        const empty: CustomNetworkMapping = {};
        protocols.set(key, empty);
      } else if (value !== 'true') { protocols.delete(key); }
    } else if (protocols.has(key)) {
      const protocol = editableNetworkMapping(document, [section, 'sniff', key], asMapping(sniff[key]));
      if (value === null) { protocol.delete(path[2]); }
      else { protocol.set(path[2], networkValue(field.kind, value)); }
    }
  }
  if (editsProtocols) {
    const protocols = root.get('sniff', true);
    if (isMap(protocols) && (protocols as ProfileYamlMapping).items.length === 0) {
      root.delete('sniffing');
      root.delete('port-whitelist');
    }
  }
}
