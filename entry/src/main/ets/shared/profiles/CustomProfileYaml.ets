import { Document, isMap, isSeq, parseDocument, ToJSOptions, ToStringOptions } from 'yaml';
import { applyCustomNetworkOptions, CustomNetworkChanges } from './CustomNetworkOptions';
import { ProfileYamlMapping, ProfileYamlSequence, readProfileYaml } from './ProfileYamlFields';

type CustomYamlFields = Record<string, Object | undefined>;
type CustomYamlDocument = Document<ProfileYamlMapping>;

export const CUSTOM_GROUP_TYPES: string[] = ['select', 'url-test', 'fallback', 'load-balance'];
export const CUSTOM_BUILTINS: string[] = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE'];
export const CUSTOM_RULE_TYPES: string[] = ['MATCH', 'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-REGEX',
  'DOMAIN-WILDCARD', 'GEOSITE', 'GEOIP', 'SRC-GEOIP', 'IP-ASN', 'SRC-IP-ASN', 'IP-CIDR', 'IP-CIDR6', 'SRC-IP-CIDR',
  'IP-SUFFIX', 'SRC-IP-SUFFIX', 'SRC-PORT', 'DST-PORT', 'IN-PORT', 'DSCP', 'PROCESS-NAME', 'PROCESS-PATH',
  'PROCESS-NAME-REGEX', 'PROCESS-PATH-REGEX', 'PROCESS-NAME-WILDCARD', 'PROCESS-PATH-WILDCARD', 'NETWORK',
  'UID', 'IN-TYPE', 'IN-USER', 'IN-NAME', 'REMATCH-NAME', 'RULE-SET', 'AND', 'OR', 'NOT', 'SUB-RULE'];
export const CUSTOM_EMPTY_YAML = 'proxies: []\nproxy-groups: []\nrules: []\n';

export interface CustomGroup {
  name: string;
  type: string;
  members: string[];
  providers: string[];
  options: string;
}

export interface CustomNode {
  name: string;
  type: string;
  dialer: string;
}

export interface CustomIssue {
  code: string;
  subject: string;
  reference: string;
  blocking: boolean;
}

export interface CustomProfileView {
  source: string;
  groups: CustomGroup[];
  nodes: CustomNode[];
  rules: string[];
  providers: string[];
  ruleProviders: string[];
  issues: CustomIssue[];
}

export interface CustomProfileMutation {
  kind: string;
  index?: number;
  offset?: number;
  group?: CustomGroup;
  text?: string;
  field?: string;
  definition?: CustomYamlFields;
  networkChanges?: CustomNetworkChanges;
}

const EDITABLE_SECTIONS: string[] = ['proxy-providers', 'rule-providers', 'dns', 'ntp', 'sniffer', 'sub-rules'];
const GROUP_FIELDS: string[] = ['name', 'type', 'proxies', 'use'];
const ALL_DIALERS = '\x00';
const YAML_OUTPUT: ToStringOptions = { lineWidth: 0 };
const YAML_INPUT: ToJSOptions = { maxAliasCount: 100 };

function fields(value: Object | undefined): CustomYamlFields {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('custom_shape');
  }
  return value as CustomYamlFields;
}

function field(mapping: CustomYamlFields, key: string): Object | undefined {
  return Object.keys(mapping).includes(key) ? mapping[key] : undefined;
}

function textField(mapping: CustomYamlFields, key: string): string {
  const value = field(mapping, key);
  return typeof value === 'string' ? value : '';
}

function list(value: Object | undefined): Object[] {
  if (value === undefined || value === null) { return []; }
  if (!Array.isArray(value)) { throw new Error('custom_shape'); }
  return value as Object[];
}

function strings(value: Object | undefined): string[] {
  return list(value).map((item: Object): string => {
    if (typeof item !== 'string') { throw new Error('custom_shape'); }
    return item;
  });
}

function mappingKeys(value: Object | undefined): string[] {
  return value === undefined || value === null ? [] : Object.keys(fields(value));
}

function stringify(value: Object): string {
  return new Document(value).toString(YAML_OUTPUT);
}

function readGroup(value: Object): CustomGroup {
  const group = fields(value);
  const empty: CustomYamlFields = {};
  const options = new Document(empty) as CustomYamlDocument;
  for (const key of Object.keys(group)) {
    const entry = group[key];
    if (entry !== undefined && !GROUP_FIELDS.includes(key)) { options.set(key, entry); }
  }
  return { name: textField(group, 'name'), type: textField(group, 'type'), members: strings(field(group, 'proxies')),
    providers: strings(field(group, 'use')),
    options: options.contents?.items.length === 0 ? '' : options.toString(YAML_OUTPUT) };
}

export function appendCustomGroupFilter(source: string, expression: string): string {
  const document = readProfileYaml(source.trim() === '' ? '{}' : source, 'invalid_yaml');
  const existing = field(rootFields(document), 'filter');
  if (existing !== undefined && typeof existing !== 'string') { throw new Error('custom_shape'); }
  const separator = String.fromCharCode(96);
  const patterns = typeof existing === 'string' ? existing.split(separator).filter((part: string): boolean => part !== '') : [];
  if (!patterns.includes(expression)) { patterns.push(expression); }
  document.set('filter', patterns.join(separator));
  return document.toString(YAML_OUTPUT);
}

function rootFields(document: CustomYamlDocument): CustomYamlFields {
  return fields(document.toJS(YAML_INPUT) as Object);
}

function openDocument(source: string): CustomYamlDocument {
  const document = readProfileYaml(source, 'invalid_yaml');
  const root = rootFields(document);
  const sections = ['proxies', 'proxy-groups', 'rules'].concat(EDITABLE_SECTIONS);
  if (!sections.some((key: string): boolean => field(root, key) !== undefined)) { throw new Error('not_clash'); }
  return document;
}

function replaceSection(document: CustomYamlDocument, key: string, source: string): void {
  const sequence = key === 'rules' || key === 'proxies';
  if (source.trim() === '') {
    if (sequence) { document.set(key, []); } else { document.delete(key); }
    return;
  }
  const input = parseDocument(source);
  if (input.errors.length > 0 || (sequence ? !isSeq(input.contents) : !isMap(input.contents))) {
    throw new Error('custom_shape');
  }
  document.set(key, input.contents as Object);
}

function editableSequence(document: CustomYamlDocument, key: string): ProfileYamlSequence {
  const node = document.get(key, true) as Object | undefined;
  if (isSeq(node)) { return node as ProfileYamlSequence; }
  const sequence = document.createNode(list(field(rootFields(document), key))) as ProfileYamlSequence;
  document.set(key, sequence);
  return sequence;
}

function editableMapping(document: CustomYamlDocument, key: string, index: number,
  sequence: ProfileYamlSequence): ProfileYamlMapping {
  const node = sequence.items[index];
  if (isMap(node) && !(node as ProfileYamlMapping).has('<<')) { return node as ProfileYamlMapping; }
  const mapping = document.createNode(fields(list(field(rootFields(document), key))[index])) as ProfileYamlMapping;
  sequence.items[index] = mapping;
  return mapping;
}

function moveOrRemove(sequence: ProfileYamlSequence, index: number, offset: number | undefined): void {
  if (index < 0 || index >= sequence.items.length) { throw new Error('conflict'); }
  if (offset === undefined) {
    sequence.items.splice(index, 1);
  } else if (index + offset >= 0 && index + offset < sequence.items.length) {
    const item = sequence.items[index];
    sequence.items.splice(index, 1);
    sequence.items.splice(index + offset, 0, item);
  }
}

function putGroup(document: CustomYamlDocument, index: number, group: CustomGroup): void {
  const sequence = editableSequence(document, 'proxy-groups');
  if (index < -1 || index >= sequence.items.length) { throw new Error('conflict'); }
  const root = rootFields(document);
  const groups = list(field(root, 'proxy-groups'));
  const original = index < 0 ? undefined : readGroup(groups[index]);
  const name = group.name.trim();
  if (original?.name !== name && (groups.some((row: Object): boolean => textField(fields(row), 'name') === name) ||
    list(field(root, 'proxies')).some((row: Object): boolean => textField(fields(row), 'name') === name))) {
    throw new Error('name_taken');
  }
  const empty: CustomYamlFields = {};
  const mapping = index < 0 ? document.createNode(empty) as ProfileYamlMapping :
    editableMapping(document, 'proxy-groups', index, sequence);
  if (original?.options !== group.options) {
    const options = group.options.trim() === '' ? undefined : readProfileYaml(group.options, 'invalid_yaml').contents;
    if (options !== undefined && options !== null && GROUP_FIELDS.some((key: string): boolean => options.has(key))) {
      throw new Error('custom_shape');
    }
    for (const pair of mapping.items.slice()) {
      const key = String(pair.key);
      if (!GROUP_FIELDS.includes(key)) { mapping.delete(key); }
    }
    if (options !== undefined && options !== null) {
      for (const pair of options.items) { mapping.items.push(pair); }
    }
  }
  if (original?.name !== name) { mapping.set('name', name); }
  if (original?.type !== group.type) { mapping.set('type', group.type); }
  updateGroupMembers(mapping, 'proxies', original?.members ?? [], group.members);
  updateGroupMembers(mapping, 'use', original?.providers ?? [], group.providers);
  if (index < 0) { sequence.items.push(mapping); }
  if (original !== undefined && original.name !== '' && name !== original.name) {
    renameTarget(document, original.name, name);
  }
}

function updateGroupMembers(mapping: ProfileYamlMapping, key: string, before: string[], after: string[]): void {
  if (before.length === after.length && before.every((name: string, index: number): boolean => name === after[index])) {
    return;
  }
  mapping.set(key, after);
}

function putNode(document: CustomYamlDocument, definition: CustomYamlFields): void {
  const name = textField(definition, 'name');
  const sequence = editableSequence(document, 'proxies');
  for (const raw of list(field(rootFields(document), 'proxies'))) {
    if (textField(fields(raw), 'name') === name) { throw new Error('name_taken'); }
  }
  sequence.items.push(document.createNode(definition));
}

function putRule(document: CustomYamlDocument, index: number, text: string): void {
  const sequence = editableSequence(document, 'rules');
  if (index < 0) { sequence.items.push(document.createNode(text)); }
  else if (index >= sequence.items.length) { throw new Error('conflict'); }
  else { sequence.set(index, text); }
}

export function customRuleParts(rule: string): string[] {
  const parts = rule.split(',').map((part: string): string => part.trim());
  if (parts.length > 3 && customRuleAllowsComma(parts[0].toUpperCase())) {
    return [parts[0], parts.slice(1, -1).join(','), parts[parts.length - 1]];
  }
  return parts;
}

export function customRuleAllowsComma(kind: string): boolean {
  return ['AND', 'OR', 'NOT', 'SUB-RULE', 'DOMAIN-REGEX', 'PROCESS-NAME-REGEX', 'PROCESS-PATH-REGEX'].includes(kind);
}

function ruleTarget(parts: string[]): number {
  return parts[0].toUpperCase() === 'MATCH' ? 1 : 2;
}

function rewriteRule(rule: string, previous: string, next: string): string {
  const parts = customRuleParts(rule);
  const index = ruleTarget(parts);
  if (parts[0].toUpperCase() === 'SUB-RULE' || parts[index] !== previous) { return rule; }
  parts[index] = next;
  return parts.join(',');
}

function rewriteRules(sequence: ProfileYamlSequence, rules: string[], previous: string, next: string): void {
  for (let i = 0; i < rules.length; i++) {
    const rule = rewriteRule(rules[i], previous, next);
    if (rule !== rules[i]) { sequence.set(i, rule); }
  }
}

function renameTarget(document: CustomYamlDocument, previous: string, next: string): void {
  const root = rootFields(document);
  for (const key of ['proxy-groups', 'proxies']) {
    const rows = list(field(root, key));
    for (let index = 0; index < rows.length; index++) {
      const row = fields(rows[index]);
      const members = strings(field(row, 'proxies'));
      const properties = ['dialer-proxy', 'default-selected'];
      if (!members.includes(previous) &&
        !properties.some((property: string): boolean => textField(row, property) === previous)) { continue; }
      const mapping = editableMapping(document, key, index, editableSequence(document, key));
      if (members.includes(previous)) {
        mapping.set('proxies', members.map((name: string): string => name === previous ? next : name));
      }
      for (const property of properties) {
        if (textField(row, property) === previous) { mapping.set(property, next); }
      }
    }
  }
  const rules = strings(field(root, 'rules'));
  if (rules.length > 0) { rewriteRules(editableSequence(document, 'rules'), rules, previous, next); }
  const subRules = field(root, 'sub-rules');
  for (const key of mappingKeys(subRules)) {
    const nested = strings(field(fields(subRules), key));
    const updated = nested.map((rule: string): string => rewriteRule(rule, previous, next));
    if (updated.some((rule: string, index: number): boolean => rule !== nested[index])) {
      document.setIn(['sub-rules', key], updated);
    }
  }
  renameNetworkTargets(document, root, previous, next);
}

function renameNetworkTargets(document: CustomYamlDocument, root: CustomYamlFields, previous: string, next: string): void {
  const ntp = field(root, 'ntp');
  if (ntp !== undefined && ntp !== null && textField(fields(ntp), 'dialer-proxy') === previous) {
    document.setIn(['ntp', 'dialer-proxy'], next);
  }
  const dns = field(root, 'dns');
  if (dns === undefined || dns === null) { return; }
  const dnsFields = fields(dns);
  for (const key of ['nameserver', 'fallback', 'default-nameserver', 'proxy-server-nameserver', 'direct-nameserver']) {
    renameDnsEntry(document, ['dns', key], field(dnsFields, key), previous, next);
  }
  for (const key of ['nameserver-policy', 'proxy-server-nameserver-policy']) {
    const policy = field(dnsFields, key);
    for (const domain of mappingKeys(policy)) {
      renameDnsEntry(document, ['dns', key, domain], field(fields(policy), domain), previous, next);
    }
  }
}

function renameDnsEntry(document: CustomYamlDocument, path: string[], entries: Object | undefined,
  previous: string, next: string): void {
  if (typeof entries === 'string') {
    const updated = renameDnsServer(entries, previous, next);
    if (entries !== updated) { document.setIn(path, updated); }
  } else if (Array.isArray(entries)) {
    const servers = strings(entries);
    const updated = servers.map((server: string): string => renameDnsServer(server, previous, next));
    if (updated.some((server: string, index: number): boolean => server !== servers[index])) {
      document.setIn(path, updated);
    }
  }
}

function renameDnsServer(server: string, previous: string, next: string): string {
  const separator = server.indexOf('#');
  if (separator < 0) { return server; }
  const options = server.slice(separator + 1).split('&');
  const updated = options.map((option: string): string => {
    if (option === previous) { return next; }
    return option === 'proxy=' + previous ? 'proxy=' + next : option;
  });
  return server.slice(0, separator + 1) + updated.join('&');
}

function executeMutation(document: CustomYamlDocument, mutation: CustomProfileMutation): void {
  const index = mutation.index ?? -1;
  const key = mutation.field ?? '';
  switch (mutation.kind) {
    case 'group':
      if (mutation.group !== undefined) { putGroup(document, index, mutation.group); }
      break;
    case 'node':
      if (mutation.definition !== undefined) { putNode(document, mutation.definition); }
      break;
    case 'dialer': {
      const sequence = editableSequence(document, 'proxies');
      if (index < 0 || index >= sequence.items.length) { throw new Error('conflict'); }
      const node = editableMapping(document, 'proxies', index, sequence);
      if (mutation.text) { node.set('dialer-proxy', mutation.text); } else { node.delete('dialer-proxy'); }
      break;
    }
    case 'rule':
      putRule(document, index, mutation.text ?? '');
      break;
    case 'section':
      if (!EDITABLE_SECTIONS.includes(key) && key !== 'rules' && key !== 'proxies') { throw new Error('custom_shape'); }
      replaceSection(document, key, mutation.text ?? '');
      break;
    case 'network':
      if (key !== 'ntp' && key !== 'sniffer') { throw new Error('custom_shape'); }
      if (mutation.networkChanges !== undefined) { applyCustomNetworkOptions(document, key, mutation.networkChanges); }
      break;
    case 'order':
      if (!['rules', 'proxy-groups', 'proxies'].includes(key)) { throw new Error('custom_shape'); }
      moveOrRemove(editableSequence(document, key), index, mutation.offset);
      break;
  }
}

export function customProfileSection(source: string, key: string): string {
  const value = field(rootFields(openDocument(source)), key);
  return value === undefined || value === null ? '' : stringify(value);
}

export function editCustomProfile(source: string, mutation?: CustomProfileMutation): CustomProfileView {
  const document = openDocument(source);
  if (mutation !== undefined) { executeMutation(document, mutation); }
  const root = rootFields(document);
  const groups = list(field(root, 'proxy-groups')).map<CustomGroup>((item: Object): CustomGroup => readGroup(item));
  const nodes = list(field(root, 'proxies')).map<CustomNode>((item: Object): CustomNode => {
    const node = fields(item);
    return { name: textField(node, 'name'), type: textField(node, 'type'), dialer: textField(node, 'dialer-proxy') };
  });
  const view: CustomProfileView = { source: mutation === undefined ? source : document.toString(YAML_OUTPUT), groups: groups,
    nodes: nodes, rules: strings(field(root, 'rules')), providers: mappingKeys(field(root, 'proxy-providers')),
    ruleProviders: mappingKeys(field(root, 'rule-providers')), issues: [] };
  view.issues = profileIssues(root, view);
  return view;
}

export function prepareCustomProfile(source: string): string {
  const document = openDocument(source);
  const root = rootFields(document);
  if (field(root, 'proxies') === undefined || field(root, 'proxies') === null) {
    document.set('proxies', []);
    return document.toString(YAML_OUTPUT);
  }
  return source;
}

function issue(code: string, subject: string, reference: string = '', blocking: boolean = true): CustomIssue {
  return { code: code, subject: subject, reference: reference, blocking: blocking };
}

function checkName(name: string, length: number, targets: Set<string>, issues: CustomIssue[]): void {
  if (name === '' || name.length > length || /[,\r\n\x00]/.test(name) ||
    name !== name.trim() || name.toUpperCase() === 'GLOBAL' || CUSTOM_BUILTINS.includes(name.toUpperCase())) {
    issues.push(issue('name', name));
  } else if (targets.has(name)) { issues.push(issue('duplicate', name)); }
  targets.add(name);
}

function groupDependencies(raw: CustomYamlFields, group: CustomGroup, targets: Set<string>,
  groups: Set<string>, providers: Set<string>, issues: CustomIssue[]): string[] {
  const autoNodes = field(raw, 'include-all') === true || field(raw, 'include-all-proxies') === true;
  const autoProviders = field(raw, 'include-all') === true || field(raw, 'include-all-providers') === true;
  const fallback = textField(raw, 'empty-fallback');
  if (!CUSTOM_GROUP_TYPES.includes(group.type)) { issues.push(issue('type', group.name, group.type)); }
  if (group.members.length === 0 && group.providers.length === 0 && !autoNodes && !autoProviders) {
    issues.push(issue('empty_group', group.name));
  }
  for (const member of group.members) {
    if (!targets.has(member)) { issues.push(issue('missing_target', group.name, member, false)); }
  }
  for (const provider of group.providers) {
    if (!providers.has(provider)) { issues.push(issue('missing_provider', group.name, provider, false)); }
  }
  if (fallback !== '' && (!targets.has(fallback) || groups.has(fallback))) {
    issues.push(issue('fallback', group.name, fallback));
  }
  const dependencies = group.members.slice();
  if (fallback !== '') { dependencies.push(fallback); }
  if (autoNodes) { dependencies.push(ALL_DIALERS); }
  return dependencies;
}

function findCycle(edges: Map<string, string[]>): string[] {
  const visited = new Set<string>();
  for (const start of edges.keys()) {
    if (visited.has(start)) { continue; }
    const path: string[] = [start];
    const positions = new Map<string, number>();
    const cursors: number[] = [0];
    positions.set(start, 0);
    while (path.length > 0) {
      const index = path.length - 1;
      const current = path[index];
      const children = edges.get(current) ?? [];
      if (cursors[index] === children.length) {
        visited.add(current);
        positions.delete(current);
        cursors.pop();
        path.pop();
        continue;
      }
      const target = children[cursors[index]++];
      const previous = positions.get(target);
      if (previous !== undefined) { return path.slice(previous).concat(target); }
      if (edges.has(target) && !visited.has(target)) {
        positions.set(target, path.length);
        path.push(target);
        cursors.push(0);
      }
    }
  }
  return [];
}

function checkRules(rules: string[], scope: string, targets: Set<string>, providers: Set<string>, subRules: Set<string>,
  issues: CustomIssue[]): void {
  rules.forEach((rule: string, index: number): void => {
    const row = scope === '' ? String(index + 1) : scope + ' / ' + String(index + 1);
    const parts = customRuleParts(rule);
    const kind = parts[0].toUpperCase();
    const target = parts[ruleTarget(parts)] ?? '';
    if (!CUSTOM_RULE_TYPES.includes(kind) || target === '' || (kind !== 'MATCH' && parts[1] === '') ||
      (kind === 'MATCH' && parts.length !== 2)) {
      issues.push(issue('rule', row));
    } else if (kind === 'SUB-RULE' && !subRules.has(target)) {
      issues.push(issue('missing_sub_rule', row, target, false));
    } else if (kind !== 'SUB-RULE' && !targets.has(target)) {
      issues.push(issue('missing_target', row, target, false));
    }
    if (kind === 'RULE-SET' && !providers.has(parts[1])) {
      issues.push(issue('missing_rule_provider', row, parts[1] ?? '', false));
    }
  });
}

function profileIssues(root: CustomYamlFields, view: CustomProfileView): CustomIssue[] {
  const issues: CustomIssue[] = [];
  const targets = new Set<string>(CUSTOM_BUILTINS);
  const groups = new Set<string>();
  const edges = new Map<string, string[]>();
  const dialers: string[] = [];
  for (const node of view.nodes) {
    checkName(node.name, 255, targets, issues);
    if (node.type === '') { issues.push(issue('type', node.name)); }
    if (node.dialer !== '') {
      edges.set(node.name, [node.dialer]);
      dialers.push(node.name);
    }
  }
  for (const group of view.groups) {
    checkName(group.name, 64, targets, issues);
    groups.add(group.name);
  }
  for (const node of view.nodes) {
    if (node.dialer !== '' && !targets.has(node.dialer)) {
      issues.push(issue('missing_target', node.name, node.dialer, false));
    }
  }
  const rawGroups = list(field(root, 'proxy-groups'));
  const providers = new Set<string>(view.providers);
  view.groups.forEach((group: CustomGroup, index: number): void => {
    edges.set(group.name, groupDependencies(fields(rawGroups[index]), group, targets, groups, providers, issues));
  });
  edges.set(ALL_DIALERS, dialers);
  const cycle = findCycle(edges).filter((name: string): boolean => name !== ALL_DIALERS);
  if (cycle.length !== 0) { issues.push(issue('cycle', cycle.join(' → '))); }
  const ruleProviders = new Set<string>(view.ruleProviders);
  const nested = field(root, 'sub-rules');
  const subRules = new Set<string>(mappingKeys(nested));
  checkRules(view.rules, '', targets, ruleProviders, subRules, issues);
  for (const name of subRules) {
    checkRules(strings(field(fields(nested), name)), name, targets, ruleProviders, subRules, issues);
  }
  return issues;
}
