import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { newId } from '../shared/profiles/Store';
import { ProfileSettingsFile, readProfileSettings, saveProfileSettings } from './ProfileSettingsFile';

export interface AddedRule {
  id: string;
  kind: string;
  payload: string;
  target: string;
  noResolve: boolean;
  source: boolean;
}

export interface AddedRulesSettings {
  revision: string;
  rules: AddedRule[];
}

export const ADDED_RULE_KINDS: string[] = [
  'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-REGEX', 'DOMAIN-WILDCARD', 'GEOSITE',
  'IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP', 'SRC-GEOIP', 'SRC-IP-ASN', 'SRC-IP-CIDR',
  'SRC-IP-SUFFIX', 'DST-PORT', 'SRC-PORT', 'IN-PORT', 'IN-TYPE', 'IN-USER', 'IN-NAME', 'REMATCH-NAME',
  'NETWORK', 'DSCP', 'AND', 'OR', 'NOT'
];

export const ADDED_RULE_TARGETS: string[] = [
  'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE', 'GLOBAL', 'MATCH'
];

export function addedRuleHasParams(kind: string): boolean {
  return ['IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP'].includes(kind);
}

export function newAddedRule(kind: string = 'DOMAIN', payload: string = '', target: string = 'DIRECT',
  noResolve: boolean = false): AddedRule {
  return { id: newId('rule.'), kind: kind, payload: payload, target: target, noResolve: noResolve, source: false };
}

export function addedRuleText(rule: AddedRule): string {
  const target = rule.target === 'MATCH' ? 'MATCH-TARGET' : rule.target;
  return [rule.kind, rule.payload, target].join(',') + (rule.noResolve ? ',no-resolve' : '') + (rule.source ? ',src' : '');
}

function validPrefix(payload: string): boolean {
  const bits = payload.split('/');
  if (bits.length !== 2 || !/^\d{1,3}$/.test(bits[1])) {
    return false;
  }
  if (bits[0].includes(':')) {
    try {
      return Number(bits[1]) <= 128 && url.URL.parseURL('http://[' + bits[0] + ']').hostname.startsWith('[');
    } catch (_error) {
      return false;
    }
  }
  const octets = bits[0].split('.');
  return Number(bits[1]) <= 32 && octets.length === 4 &&
    octets.every((octet: string): boolean => /^(0|[1-9]\d{0,2})$/.test(octet) && Number(octet) <= 255);
}

export function validAddedRule(rule: AddedRule): boolean {
  if (rule === null || typeof rule !== 'object' || typeof rule.id !== 'string' || rule.id === '' ||
    rule.id.length > 80 || !ADDED_RULE_KINDS.includes(rule.kind) || !ADDED_RULE_TARGETS.includes(rule.target) ||
    typeof rule.payload !== 'string' || rule.payload === '' || rule.payload.length > 2048 ||
    rule.payload.trim() !== rule.payload || /[\x00\r\n]/.test(rule.payload) ||
    typeof rule.noResolve !== 'boolean' || typeof rule.source !== 'boolean' ||
    ((rule.noResolve || rule.source) && !addedRuleHasParams(rule.kind))) {
    return false;
  }
  const payload = rule.payload;
  if (['AND', 'OR', 'NOT'].includes(rule.kind)) {
    return payload.startsWith('(') && payload.endsWith(')') &&
      !/\(\s*(RULE-SET|SUB-RULE|UID|PROCESS-[A-Z-]+)\s*,/i.test(payload);
  }
  if (rule.kind === 'DOMAIN-REGEX') {
    return true;
  }
  if (payload.includes(',')) {
    return false;
  }
  if (['IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'SRC-IP-CIDR', 'SRC-IP-SUFFIX'].includes(rule.kind)) {
    return validPrefix(payload);
  }
  return rule.kind !== 'NETWORK' || ['TCP', 'UDP'].includes(payload.toUpperCase());
}

export function emptyAddedRules(): AddedRulesSettings {
  return { revision: 'default', rules: [] };
}

function checked(settings: AddedRulesSettings): AddedRulesSettings {
  if (settings === null || typeof settings !== 'object' || typeof settings.revision !== 'string' ||
    settings.revision === '' || settings.revision.length > 80 || !Array.isArray(settings.rules) ||
    settings.rules.length > 1000) {
    throw new Error('profile_settings_invalid');
  }
  const ids = new Set<string>();
  for (const rule of settings.rules) {
    if (!validAddedRule(rule) || ids.has(rule.id)) {
      throw new Error('profile_settings_invalid');
    }
    ids.add(rule.id);
  }
  return settings;
}

const storage: ProfileSettingsFile<AddedRulesSettings> = {
  fileName: 'added-rules.json', endpoint: '/arkclash/rules/settings', errorPrefix: 'profile_settings',
  defaults: emptyAddedRules, checked: checked
};

export function readAddedRules(filesDir: string): Promise<AddedRulesSettings> {
  return readProfileSettings<AddedRulesSettings>(filesDir, storage);
}

export function saveAddedRules(context: common.UIAbilityContext, expectedRevision: string,
  rules: AddedRule[]): Promise<AddedRulesSettings> {
  return saveProfileSettings<AddedRulesSettings>(context, storage, expectedRevision,
    { revision: newId('rules.'), rules: rules });
}
