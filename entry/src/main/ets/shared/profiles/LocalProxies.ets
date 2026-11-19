import { util } from '@kit.ArkTS';
import { newId, validProfileId } from './Store';
import { copyProxyKey, PROXY_TYPES, ProxyDefinition, proxyMap, proxyText, proxyValue, REQUIRED_PROXY_KEYS,
  withProxyValue } from './LocalProxySchema';

export const LOCAL_PROXY_LIMIT = 4 * 1024 * 1024;
export const LOCAL_PROXY_COUNT = 5000;

export interface LocalProxy {
  id: string;
  revision: string;
  definition: ProxyDefinition;
  emptyOptions: string[];
}

export interface LocalProxySnapshot {
  version: number;
  revision: string;
  proxies: LocalProxy[];
}

export interface ProxyLinkLine {
  number: number;
  link: string;
  kept: LocalProxy | undefined;
}

export interface ProxyLinkPlan {
  lines: ProxyLinkLine[];
  dropped: LocalProxy[];
}

const RESERVED = ['DIRECT', 'REJECT', 'REJECT-DROP', 'COMPATIBLE', 'PASS', 'PASS-RULE', 'GLOBAL'];

export function emptyLocalProxies(): LocalProxySnapshot { return { version: 1, revision: '', proxies: [] }; }

export function localProxyName(item: LocalProxy): string { return proxyText(item.definition, ['name']); }
export function localProxyType(item: LocalProxy): string { return proxyText(item.definition, ['type']); }

export function localProxyProblem(definition: ProxyDefinition): string {
  const name = proxyText(definition, ['name']).trim();
  const type = proxyText(definition, ['type']);
  if (name === '') { return 'local_proxy_name_empty'; }
  if (name.length > 255 || name.includes(',') || name.includes('\n') || name.includes('\r') || name.includes('\x00')) {
    return 'local_proxy_name_format';
  }
  if (RESERVED.includes(name)) { return 'local_proxy_name_reserved'; }
  if (!PROXY_TYPES.includes(type)) { return 'local_proxy_type'; }
  if (proxyText(definition, ['server']).length > 512) { return 'local_proxy_server_length'; }
  const port = proxyText(definition, ['port']);
  if (port !== '' && (!new RegExp('^[0-9]{1,5}$').test(String(port)) ||
    Number(port) < 1 || Number(port) > 65535)) { return 'local_proxy_port'; }
  for (const key of REQUIRED_PROXY_KEYS[type] ?? []) {
    if (proxyText(definition, [key]).trim() === '') { return 'local_proxy_required'; }
  }
  return '';
}

export function localProxyMatches(proxy: LocalProxy, query: string): boolean {
  const search = query.trim().toLowerCase();
  if (search === '') { return true; }
  const terms = search.split(new RegExp('\\s+'));
  const values = ['name', 'type', 'server'].map((key: string): string =>
    proxyText(proxy.definition, [key]).toLowerCase());
  return terms.every((term: string): boolean => values.some((value: string): boolean => value.includes(term)));
}

export function decodeProxyStore(text: string): LocalProxySnapshot {
  const stored = JSON.parse(text) as LocalProxySnapshot;
  if (stored === null || stored.version !== 1 || !validProfileId(stored.revision) || !Array.isArray(stored.proxies) ||
    stored.proxies.length > LOCAL_PROXY_COUNT) {
    throw new Error('local_proxy_store');
  }
  const ids = new Set<string>();
  for (const item of stored.proxies) {
    if (item === null || !validProfileId(item.id) || !validProfileId(item.revision) || ids.has(item.id) ||
      proxyMap(item.definition) === undefined || !Array.isArray(item.emptyOptions)) {
      throw new Error('local_proxy_store');
    }
    ids.add(item.id);
  }
  return stored;
}

export function encodeProxyStore(stored: LocalProxySnapshot): string {
  if (stored.proxies.length > LOCAL_PROXY_COUNT) { throw new Error('local_proxy_input'); }
  const names = new Set<string>();
  const ids = new Set<string>();
  for (const item of stored.proxies) {
    const name = localProxyName(item);
    if (names.has(name)) { throw new Error('local_proxy_name_taken'); }
    if (ids.has(item.id)) { throw new Error('local_proxy_conflict'); }
    names.add(name);
    ids.add(item.id);
  }
  const text = JSON.stringify(stored);
  if (text.length > LOCAL_PROXY_LIMIT || new util.TextEncoder().encodeInto(text).byteLength > LOCAL_PROXY_LIMIT) {
    throw new Error('local_proxy_input');
  }
  return text;
}

export function newLocalProxy(definition: ProxyDefinition, emptyOptions: string[] = [], id: string = ''): LocalProxy {
  return { id: id || newId('node'), revision: newId('r'), definition: definition, emptyOptions: emptyOptions };
}

export function checkProxyName(snapshot: LocalProxySnapshot, definition: ProxyDefinition, id: string): string {
  const name = proxyText(definition, ['name']).trim();
  return snapshot.proxies.some((proxy: LocalProxy): boolean =>
    proxy.id !== id && localProxyName(proxy) === name) ? 'local_proxy_name_taken' : '';
}

export function planProxyLinks(snapshot: LocalProxySnapshot, links: string[], text: string): ProxyLinkPlan {
  const unused = new Map<string, LocalProxy[]>();
  snapshot.proxies.forEach((proxy: LocalProxy, index: number): void => {
    const link = links[index];
    if (link === '') { return; }
    const matches = unused.get(link) ?? [];
    matches.push(proxy);
    unused.set(link, matches);
  });
  const lines: ProxyLinkLine[] = [];
  const keptIds = new Set<string>();
  text.split('\n').forEach((raw: string, index: number): void => {
    const link = raw.trim();
    if (link === '') { return; }
    const kept = unused.get(link)?.shift();
    if (kept !== undefined) { keptIds.add(kept.id); }
    lines.push({ number: index + 1, link: link, kept: kept });
  });
  const dropped = snapshot.proxies.filter((item: LocalProxy, index: number): boolean =>
    links[index] !== '' && !keptIds.has(item.id));
  return { lines: lines, dropped: dropped };
}

export function mergeProxyLink(next: ProxyDefinition, previous: ProxyDefinition,
  linked: ProxyDefinition | undefined): ProxyDefinition {
  if (linked === undefined || proxyText(next, ['type']) !== proxyText(previous, ['type'])) { return next; }
  return mergeUnlinked(next, previous, linked);
}

function mergeUnlinked(next: ProxyDefinition, previous: ProxyDefinition, linked: ProxyDefinition): ProxyDefinition {
  const result: ProxyDefinition = {};
  for (const key of Object.keys(next)) {
    if (copyProxyKey(key)) { result[key] = next[key]; }
  }
  for (const key of Object.keys(previous)) {
    if (!copyProxyKey(key)) { continue; }
    const oldLink = proxyValue(linked, [key]);
    const newLink = proxyValue(result, [key]);
    if (oldLink === undefined && newLink === undefined) {
      result[key] = previous[key];
    } else {
      const oldMap = proxyMap(oldLink);
      const newMap = proxyMap(newLink);
      const savedMap = proxyMap(previous[key]);
      if (oldMap !== undefined && newMap !== undefined && savedMap !== undefined) {
        result[Object.keys(result).find((name: string): boolean => name.toLowerCase() === key.toLowerCase()) ?? key] =
          mergeUnlinked(newMap, savedMap, oldMap);
      }
    }
  }
  return result;
}

function importedName(definition: ProxyDefinition): string {
  const name = proxyText(definition, ['name']).trim();
  const base = new RegExp('^(-[0-9]+)?$').test(name) ?
    proxyText(definition, ['server']) || proxyText(definition, ['type']) : name;
  return base.replace(new RegExp('[,\\x00\\r\\n]', 'g'), '-').slice(0, 255);
}

function uniqueProxyName(base: string, used: Set<string>): string {
  let name = base;
  let index = 1;
  while (used.has(name)) {
    const ending = `-${String(index++).padStart(2, '0')}`;
    name = base.slice(0, 255 - ending.length) + ending;
  }
  used.add(name);
  return name;
}

export function nameProxyFromLink(definition: ProxyDefinition, snapshot: LocalProxySnapshot,
  current: LocalProxy | undefined, currentName: string): ProxyDefinition {
  if (proxyText(definition, ['name']).trim() === '' && currentName.trim() !== '') {
    return withProxyValue(definition, ['name'], currentName);
  }
  const taken = new Set<string>(RESERVED);
  for (const item of snapshot.proxies) {
    if (item.id !== current?.id) { taken.add(localProxyName(item)); }
  }
  return withProxyValue(definition, ['name'], uniqueProxyName(importedName(definition), taken));
}

export function applyProxyLinkPlan(snapshot: LocalProxySnapshot, links: string[], plan: ProxyLinkPlan,
  decoded: Map<number, ProxyDefinition[]>, originals: Map<string, ProxyDefinition>): LocalProxy[] {
  const used = new Set<string>(RESERVED);
  const kept = new Set<string>();
  for (const line of plan.lines) {
    if (line.kept !== undefined) {
      kept.add(line.kept.id);
      used.add(localProxyName(line.kept));
    }
  }
  const opaque = new Map<string, LocalProxy[]>();
  let anchor = '';
  snapshot.proxies.forEach((item: LocalProxy, index: number): void => {
    if (links[index] === '') {
      used.add(localProxyName(item));
      const entries = opaque.get(anchor) ?? [];
      entries.push(item);
      opaque.set(anchor, entries);
    } else if (kept.has(item.id)) {
      anchor = item.id;
    }
  });
  const dropped = new Map<string, LocalProxy>();
  for (const item of plan.dropped) { dropped.set(localProxyName(item), item); }
  const result: LocalProxy[] = (opaque.get('') ?? []).slice();
  for (const line of plan.lines) {
    if (line.kept !== undefined) {
      result.push(line.kept);
      result.push(...(opaque.get(line.kept.id) ?? []));
      continue;
    }
    for (const definition of decoded.get(line.number) ?? []) {
      const base = importedName(definition);
      const old = used.has(base) ? undefined : dropped.get(base);
      const named = withProxyValue(definition, ['name'], uniqueProxyName(base, used));
      const next = old === undefined ? named : mergeProxyLink(named, old.definition, originals.get(old.id));
      const problem = localProxyProblem(next);
      if (problem !== '') { throw new Error(`local_proxy_line|${line.number}|${problem}`); }
      result.push(newLocalProxy(next, old?.emptyOptions ?? [], old?.id));
    }
  }
  return result;
}
