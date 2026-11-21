import { Document, isAlias, isMap, isScalar, Scalar, ToJSOptions } from 'yaml';
import {
  ProfileYamlGroup, ProfileYamlMapping, profileYamlGroup, profileYamlGroups, readProfileYaml, writeProfileYamlField
} from './ProfileYamlFields';

export type ProxyFilterField = 'filter' | 'exclude-filter';

export interface ProxyFilterTarget {
  kind: 'group' | 'provider';
  name: string;
  index: number;
}

export function filterTargets(text: string): ProxyFilterTarget[] {
  const document = readProfileYaml(text, 'proxy_filter_yaml');
  const targets: ProxyFilterTarget[] = [];
  const root = document.contents as ProfileYamlMapping;
  for (const group of profileYamlGroups(root)) {
    targets.push({ kind: 'group', name: group.name, index: group.index });
  }
  const providers = root.get('proxy-providers');
  if (isMap(providers)) {
    for (const pair of (providers as ProfileYamlMapping).items) {
      if (!isScalar(pair.key) || !isMap(pair.value)) { continue; }
      const name = (pair.key as Scalar<Object>).value;
      if (typeof name === 'string' && name !== '') {
        targets.push({ kind: 'provider', name: name, index: -1 });
      }
    }
  }
  return targets;
}

function findTarget(root: ProfileYamlMapping, target: ProxyFilterTarget): ProfileYamlMapping {
  if (target.kind === 'group') {
    const key: ProfileYamlGroup = { name: target.name, index: target.index };
    const group = profileYamlGroup(root, key);
    if (group !== undefined) { return group; }
  } else {
    const providers = root.get('proxy-providers');
    if (isMap(providers)) {
      const provider = (providers as ProfileYamlMapping).get(target.name);
      if (isMap(provider)) { return provider as ProfileYamlMapping; }
    }
  }
  throw new Error('proxy_filter_yaml_target');
}

function effectiveFilter(document: Document<ProfileYamlMapping>, destination: ProfileYamlMapping, target: ProxyFilterTarget,
  field: ProxyFilterField): string {
  const node = destination.get(field, true);
  if (destination.anchor !== undefined || (isScalar(node) && node.anchor !== undefined)) {
    // 直接改写锚点会同时改变其他代理组或代理集合。
    throw new Error('proxy_filter_yaml_value');
  }
  if (typeof node?.value === 'string') { return node.value; }
  if (node === undefined || isAlias(node)) {
    const options: ToJSOptions = { maxAliasCount: 100 };
    const resolved = document.toJS(options) as Record<string, Object>;
    const group = target.kind === 'group' ?
      (resolved['proxy-groups'] as Record<string, Object>[])[target.index] :
      (resolved['proxy-providers'] as Record<string, Record<string, Object>>)[target.name];
    const value = group[field];
    if (typeof value === 'string') { return value; }
    if (value === undefined || value === null) { return ''; }
  }
  if (isScalar(node) && node.value === null) { return ''; }
  throw new Error('proxy_filter_yaml_value');
}

export function filterIntoYaml(text: string, target: ProxyFilterTarget, field: ProxyFilterField, expression: string): string {
  const document = readProfileYaml(text, 'proxy_filter_yaml');
  const destination = findTarget(document.contents as ProfileYamlMapping, target);
  const existing = effectiveFilter(document, destination, target, field);
  const parts = existing.split('`');
  const seen = new Set<string>(parts);
  const additions: string[] = [];
  for (const part of expression.split('`')) {
    if (part !== '' && !seen.has(part)) {
      additions.push(part);
      seen.add(part);
    }
  }
  if (additions.length === 0) { return text; }
  const value = existing === '' ? additions.join('`') : existing + '`' + additions.join('`');
  return writeProfileYamlField(text, document, destination, field, value);
}
