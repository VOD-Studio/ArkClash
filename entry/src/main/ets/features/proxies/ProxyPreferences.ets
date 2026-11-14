import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { copyProxyStyle, defaultProxyStyle, ProxyStyle, ProxyViewState } from './ProxyLogic';

interface ProxySavedStyle {
  revision: number;
  style: ProxyStyle;
}

interface ProxySavedView {
  revision: number;
  expanded: string[];
  currentGroup: string;
}

export interface ProxyViewPatch {
  expanded?: string[];
  currentGroup?: string;
}

export interface ProxyViewCommit {
  revision: number;
  view: ProxyViewState;
}

export interface ProxyPreferenceSnapshot {
  style: ProxyStyle;
  styleRevision: number;
  view: ProxyViewState;
  viewRevision: number;
  closeConnections: boolean;
}

let proxyPreferences: Promise<preferences.Preferences> | undefined;
let proxyPreferenceWrites: Promise<void> = Promise.resolve();

function settings(context: common.UIAbilityContext): Promise<preferences.Preferences> {
  if (proxyPreferences !== undefined) {
    return proxyPreferences;
  }
  const pending = preferences.getPreferences(context, { name: 'settings' });
  proxyPreferences = pending;
  pending.catch((): void => {
    if (proxyPreferences === pending) {
      proxyPreferences = undefined;
    }
  });
  return pending;
}

function styleRecord(text: string): ProxySavedStyle {
  if (text === '') {
    return { revision: 0, style: defaultProxyStyle() };
  }
  const saved = JSON.parse(text) as ProxySavedStyle;
  const style = saved.style;
  if (style === undefined ||
    !['none', 'name', 'delay'].includes(style.sortType) ||
    !['loose', 'standard', 'compact'].includes(style.layout) ||
    !['loose', 'standard', 'compact'].includes(style.cardType) ||
    !['filled', 'icon', 'hidden'].includes(style.iconStyle) || typeof style.hideTimeoutProxies !== 'boolean' ||
    typeof saved.revision !== 'number') {
    throw new Error('proxy_style_invalid');
  }
  return { revision: saved.revision, style: copyProxyStyle(style) };
}

function viewRecord(text: string): ProxySavedView {
  if (text === '') {
    return { revision: 0, expanded: [], currentGroup: '' };
  }
  const saved = JSON.parse(text) as ProxySavedView;
  if (!Array.isArray(saved.expanded) || typeof saved.currentGroup !== 'string' ||
    typeof saved.revision !== 'number' || !saved.expanded.every((name: string): boolean => typeof name === 'string')) {
    throw new Error('proxy_view_invalid');
  }
  return saved;
}

export async function loadProxyPreferences(context: common.UIAbilityContext,
  profile: string): Promise<ProxyPreferenceSnapshot> {
  await proxyPreferenceWrites;
  const prefs = await settings(context);
  const style = styleRecord(await prefs.get('proxyStyle', '') as string);
  const view = viewRecord(await prefs.get(`proxyView.${profile}`, '') as string);
  return {
    style: copyProxyStyle(style.style), styleRevision: style.revision,
    view: { expanded: view.expanded.slice(), currentGroup: view.currentGroup }, viewRevision: view.revision,
    closeConnections: await prefs.get('closeConnections', true) as boolean
  };
}

async function commitPreference(prefs: preferences.Preferences, key: string, before: string,
  after: string): Promise<void> {
  try {
    await prefs.put(key, after);
    await prefs.flush();
  } catch (e) {
    // flush 失败时恢复 preferences 内存值，避免下一次无关保存把草稿落盘。
    await prefs.put(key, before);
    throw e as Error;
  }
}

export async function saveProxyStyle(context: common.UIAbilityContext, expectedRevision: number,
  style: ProxyStyle): Promise<number> {
  let revision = expectedRevision;
  const write = proxyPreferenceWrites.then(async (): Promise<void> => {
    const prefs = await settings(context);
    const before = await prefs.get('proxyStyle', '') as string;
    const saved = styleRecord(before);
    if (saved.revision !== expectedRevision) {
      throw new Error('proxy_style_conflict');
    }
    saved.style = copyProxyStyle(style);
    saved.revision++;
    await commitPreference(prefs, 'proxyStyle', before, JSON.stringify(saved));
    revision = saved.revision;
  });
  proxyPreferenceWrites = write.then((): void => {}, (): void => {});
  await write;
  return revision;
}

export async function saveProxyView(context: common.UIAbilityContext, profile: string,
  expectedRevision: number, patch: ProxyViewPatch): Promise<ProxyViewCommit> {
  const write = proxyPreferenceWrites.then(async (): Promise<ProxyViewCommit> => {
    const prefs = await settings(context);
    const key = `proxyView.${profile}`;
    const before = await prefs.get(key, '') as string;
    const saved = viewRecord(before);
    if (saved.revision !== expectedRevision) {
      throw new Error('proxy_view_conflict');
    }
    if (patch.expanded !== undefined) {
      saved.expanded = patch.expanded.slice();
    }
    if (patch.currentGroup !== undefined) {
      saved.currentGroup = patch.currentGroup;
    }
    saved.revision++;
    await commitPreference(prefs, key, before, JSON.stringify(saved));
    const view: ProxyViewState = { expanded: saved.expanded, currentGroup: saved.currentGroup };
    return { revision: saved.revision, view: view };
  });
  proxyPreferenceWrites = write.then((): void => {}, (): void => {});
  return await write;
}
