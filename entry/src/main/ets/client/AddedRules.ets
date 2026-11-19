import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { findProfile, newId, readListAsync, validProfileId } from '../shared/profiles/Store';
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
  profiles?: ProfileAddedRules[];
}

export interface ProfileAddedRules {
  profile: string;
  revision: string;
  rules: AddedRule[];
  disabled: string[];
  matchTarget: string;
}

export const ADDED_RULE_KINDS: string[] = [
  'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-REGEX', 'DOMAIN-WILDCARD', 'GEOSITE',
  'IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP', 'SRC-GEOIP', 'SRC-IP-ASN', 'SRC-IP-CIDR',
  'SRC-IP-SUFFIX', 'DST-PORT', 'SRC-PORT', 'IN-PORT', 'IN-TYPE', 'IN-USER', 'IN-NAME', 'REMATCH-NAME',
  'NETWORK', 'DSCP', 'AND', 'OR', 'NOT', 'RULE-SET'
];

export const ADDED_RULE_TARGETS: string[] = [
  'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE', 'GLOBAL', 'MATCH'
];

export function addedRuleHasParams(kind: string): boolean {
  return ['IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP', 'RULE-SET'].includes(kind);
}

export function newAddedRule(kind: string = 'DOMAIN', payload: string = '', target: string = 'DIRECT',
  noResolve: boolean = false): AddedRule {
  return { id: newId('rule.'), kind: kind, payload: payload, target: target, noResolve: noResolve, source: false };
}

export function addedRuleText(rule: AddedRule, label: string = rule.payload): string {
  const target = rule.target === 'MATCH' ? 'MATCH-TARGET' : rule.target;
  return [rule.kind, label, target].join(',') + (rule.noResolve ? ',no-resolve' : '') + (rule.source ? ',src' : '');
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
  if (rule.kind === 'RULE-SET') {
    return /^[a-z0-9][a-z0-9-]{0,79}$/.test(payload);
  }
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

export function profileAddedRules(settings: AddedRulesSettings, id: string): ProfileAddedRules {
  return settings.profiles?.find((item: ProfileAddedRules): boolean => item.profile === id) ??
    { profile: id, revision: '', rules: [], disabled: [], matchTarget: '' };
}

function validRevision(revision: string): boolean {
  return typeof revision === 'string' && revision !== '' && revision.length <= 80;
}

function validRuleList(rules: AddedRule[]): boolean {
  if (!Array.isArray(rules) || rules.length > 1000) { return false; }
  const ids = new Set<string>();
  for (const rule of rules) {
    if (!validAddedRule(rule) || ids.has(rule.id)) { return false; }
    ids.add(rule.id);
  }
  return true;
}

function checked(settings: AddedRulesSettings): AddedRulesSettings {
  if (settings === null || typeof settings !== 'object' || !validRevision(settings.revision) ||
    !validRuleList(settings.rules) || (settings.profiles !== undefined && !Array.isArray(settings.profiles))) {
    throw new Error('profile_settings_invalid');
  }
  const ids = new Set<string>();
  for (const item of settings.profiles ?? []) {
    if (item === null || !validProfileId(item.profile) || ids.has(item.profile) || !validRevision(item.revision) ||
      !validRuleList(item.rules) || !Array.isArray(item.disabled) || item.disabled.length > 1000 ||
      item.disabled.some((id: string): boolean => typeof id !== 'string' || id === '' || id.length > 80) ||
      typeof item.matchTarget !== 'string' || item.matchTarget.length > 1024 ||
      item.matchTarget.trim() !== item.matchTarget || /[,\x00\r\n]/.test(item.matchTarget)) {
      throw new Error('profile_settings_invalid');
    }
    ids.add(item.profile);
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

export async function saveAddedRules(context: common.UIAbilityContext, expected: AddedRulesSettings,
  rules: AddedRule[], edit?: ProfileAddedRules): Promise<AddedRulesSettings> {
  const revision = newId('rules.');
  const list = await readListAsync(context.filesDir);
  if (edit !== undefined) {
    const profile = findProfile(list, edit.profile);
    if (profile === undefined || profile.type === 'custom' || edit.revision !== profileAddedRules(expected, edit.profile).revision) {
      throw new Error('profile_settings_conflict');
    }
  }
  const globals = new Set<string>(rules.map((rule: AddedRule): string => rule.id));
  const profiles = (expected.profiles ?? []).filter((item: ProfileAddedRules): boolean =>
    item.profile !== edit?.profile && findProfile(list, item.profile) !== undefined)
    .map((item: ProfileAddedRules): ProfileAddedRules => ({ profile: item.profile, revision: item.revision,
      rules: item.rules, matchTarget: item.matchTarget,
      disabled: item.disabled.filter((id: string): boolean => globals.has(id)) }));
  if (edit !== undefined) {
    profiles.push({ profile: edit.profile, revision: revision, rules: edit.rules, matchTarget: edit.matchTarget,
      disabled: edit.disabled.filter((id: string): boolean => globals.has(id)) });
  }
  return saveProfileSettings<AddedRulesSettings>(context, storage, expected.revision,
    { revision: revision, rules: rules, profiles: profiles });
}
