import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { readOptionalText, readProfileListFile, validProfileId, writeProfileText } from '../shared/profiles/Store';

type BackupPreferenceValue = string | number | boolean;

interface BackupPreferenceGroup {
  name: string;
  keys: string[];
}

const groups: BackupPreferenceGroup[] = [
  { name: 'appearance', keys: ['appearance'] },
  { name: 'app-update', keys: ['autoCheck'] },
  { name: 'vpn_network', keys: ['settings'] },
  { name: 'script-editor', keys: ['font', 'wrap'] },
  { name: 'settings', keys: ['outboundMode', 'allowLan', 'closeConnections', 'proxyStyle',
    'diagnostics.requestFeed', 'diagnostics.grouping', 'diagnostics.columnWidths.requests',
    'diagnostics.columnWidths.connections', 'diagnostics.columnWidths.dns'] }
];

interface BackupPreferenceData {
  revision: string;
  stores: Record<string, Record<string, BackupPreferenceValue>>;
}

function decodePreferences(text: string): BackupPreferenceData {
  const snapshot = JSON.parse(text) as BackupPreferenceData;
  if (snapshot === null || !validProfileId(snapshot.revision) || snapshot.stores === null ||
    typeof snapshot.stores !== 'object' || Array.isArray(snapshot.stores)) { throw new Error('backup_invalid'); }
  for (const group of groups) {
    const values = snapshot.stores[group.name];
    if (values === undefined) { continue; }
    if (values === null || typeof values !== 'object' || Array.isArray(values)) { throw new Error('backup_invalid'); }
    for (const key of group.keys) {
      const value = values[key];
      if (value === undefined) { continue; }
      if (!portableValue(value) || (typeof value === 'string' && value.length > 128 * 1024)) {
        throw new Error('backup_invalid');
      }
    }
  }
  return snapshot;
}

export async function validateBackupPreferences(directory: string): Promise<void> {
  const text = await readOptionalText(`${directory}/portable-preferences.json`);
  if (text !== undefined) { decodePreferences(text); }
}

function portableValue(data: preferences.ValueType): boolean {
  return typeof data === 'string' || typeof data === 'number' || typeof data === 'boolean';
}

export async function exportBackupPreferences(context: common.UIAbilityContext, path: string,
  revision: string): Promise<void> {
  const snapshot: BackupPreferenceData = { revision: revision, stores: {} };
  for (const group of groups) {
    const store = await preferences.getPreferences(context, { name: group.name });
    const saved = await store.getAll() as Record<string, preferences.ValueType>;
    const selected: Record<string, BackupPreferenceValue> = {};
    for (const key of group.keys) {
      const value = saved[key];
      if (portableValue(value)) { selected[key] = value as BackupPreferenceValue; }
    }
    snapshot.stores[group.name] = selected;
  }
  await writeProfileText(path, JSON.stringify(snapshot));
}

interface BackupProfileViews {
  revision: string;
  views: Record<string, string>;
}

export async function exportBackupViews(context: common.UIAbilityContext, directory: string,
  revision: string): Promise<void> {
  const store = await preferences.getPreferences(context, { name: 'settings' });
  const saved = await store.getAll() as Record<string, preferences.ValueType>;
  const list = await readProfileListFile(`${directory}/list.json`);
  const copy: BackupProfileViews = { revision: revision, views: {} };
  for (const profile of list.profiles) {
    const view = saved[`proxyView.${profile.id}`];
    if (typeof view === 'string' && view.length <= 128 * 1024) { copy.views[profile.id] = view; }
  }
  await writeProfileText(`${directory}/profile-views.json`, JSON.stringify(copy));
}

export async function planBackupViews(source: string, next: string, revision: string): Promise<void> {
  const data = await readOptionalText(`${source}/profile-views.json`);
  if (data === undefined) { return; }
  const imported = JSON.parse(data) as BackupProfileViews;
  if (imported === null || imported.views === null || typeof imported.views !== 'object' ||
    Array.isArray(imported.views)) { throw new Error('backup_invalid'); }
  const list = await readProfileListFile(`${source}/list.json`);
  const planned: BackupProfileViews = { revision: revision, views: {} };
  for (const profile of list.profiles) {
    const view = imported.views[profile.id] ?? '';
    if (typeof view !== 'string' || view.length > 128 * 1024) { throw new Error('backup_invalid'); }
    if (view !== '') {
      const fields = JSON.parse(view) as Record<string, Object>;
      if (fields === null || !Number.isInteger(fields['revision'] as number) || !Array.isArray(fields['expanded']) ||
        typeof fields['currentGroup'] !== 'string') { throw new Error('backup_invalid'); }
    }
    planned.views[profile.id] = view;
  }
  await writeProfileText(`${next}/profile-views.json`, JSON.stringify(planned));
}

async function applyBackupViews(context: common.UIAbilityContext, journal: preferences.Preferences): Promise<boolean> {
  const text = await readOptionalText(`${context.filesDir}/profiles/profile-views.json`);
  if (text === undefined) { return false; }
  const snapshot = JSON.parse(text) as BackupProfileViews;
  if (await journal.get('views', '') === snapshot.revision) { return false; }
  const store = await preferences.getPreferences(context, { name: 'settings' });
  for (const profile of Object.keys(snapshot.views)) {
    if (!validProfileId(profile)) { throw new Error('backup_invalid'); }
    const key = `proxyView.${profile}`;
    if (snapshot.views[profile] === '') { await store.delete(key); }
    else { await store.put(key, snapshot.views[profile]); }
  }
  await store.flush();
  await journal.put('views', snapshot.revision);
  await journal.flush();
  return true;
}

export async function applyBackupPreferences(context: common.UIAbilityContext): Promise<boolean> {
  const journal = await preferences.getPreferences(context, { name: 'backup-preferences' });
  const viewsChanged = await applyBackupViews(context, journal);
  const path = `${context.filesDir}/profiles/portable-preferences.json`;
  const text = await readOptionalText(path);
  if (text === undefined) { return viewsChanged; }
  const snapshot = decodePreferences(text);
  if (await journal.get('applied', '') === snapshot.revision) { return viewsChanged; }
  for (const group of groups) {
    const imported = snapshot.stores[group.name];
    if (imported === undefined) { continue; }
    const store = await preferences.getPreferences(context, { name: group.name });
    for (const key of group.keys) {
      const value = imported[key];
      if (portableValue(value)) { await store.put(key, value); }
      else { await store.delete(key); }
    }
    await store.flush();
  }
  await journal.put('applied', snapshot.revision);
  await journal.flush();
  return true;
}
