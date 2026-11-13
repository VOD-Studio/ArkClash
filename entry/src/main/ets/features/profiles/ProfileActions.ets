import { fileIo as fs } from '@kit.CoreFileKit';
import { validSubscriptionUrl } from '../../shared/profiles/Download';
import { ProfileError } from '../../shared/profiles/Errors';
import {
  candidatePath, checkProfileCommit, findProfile, findSubscription, intervalMinutes, listPath, newId, ProfileList,
  ProfileRecord, readListAsync, readOptionalText, removeProfileFile, selectedPath, statePath, SubscriptionRecord,
  summaryPath, withProfileStorage, withProfileTask, writeList,
  writeProfileText, yamlPath
} from '../../shared/profiles/Store';
import { commitCandidate, ProfileCandidateChange, UpdateEnv } from '../../shared/profiles/Updater';
import { ProfileEdit, ProfileLinkEntry, ProfileLinkInput } from './ProfileModels';

export function parseProfileLinks(text: string, existingUrls: string[]): ProfileLinkInput {
  const result: ProfileLinkInput = { entries: [], skipped: 0, errors: [] };
  const seen = new Set<string>(existingUrls);
  const lines = text.split(new RegExp('\\r?\\n'));
  for (let index = 0; index < lines.length; index++) {
    let line = lines[index].trim().replace(new RegExp('^-\\s+'), '').replace(new RegExp(',\\s*$'), '').trim();
    if ((line.startsWith('"') && line.endsWith('"')) || (line.startsWith("'") && line.endsWith("'"))) {
      line = line.substring(1, line.length - 1).trim();
    }
    if (line === '') {
      continue;
    }
    for (const source of line.split(new RegExp('\\s+'))) {
      if (!validSubscriptionUrl(source)) {
        result.errors.push(index + 1);
      } else if (seen.has(source)) {
        result.skipped++;
      } else {
        seen.add(source);
        const entry: ProfileLinkEntry = { source: source, line: index + 1 };
        result.entries.push(entry);
      }
    }
  }
  return result;
}

function applyMetadata(list: ProfileList, id: string, edit: ProfileEdit): boolean {
  const record = findProfile(list, id);
  if (record === undefined) {
    throw new ProfileError('not_found');
  }
  const name = edit.name.trim();
  if (name.length === 0 || name.length > 64) {
    throw new ProfileError(name.length === 0 ? 'name_empty' : 'name_long');
  }
  if (list.profiles.some((profile: ProfileRecord): boolean => profile.id !== id && profile.name === name)) {
    throw new ProfileError('name_taken');
  }
  if (edit.baseName !== undefined && record.name !== edit.baseName && record.name !== name) {
    throw new ProfileError('conflict');
  }
  let sourceChanged = false;
  const sub = findSubscription(list, record.subscription);
  if (sub !== undefined) {
    const source = edit.url.trim();
    const interval = edit.intervalMinutes ?? (edit.intervalHours ?? intervalMinutes(sub) / 60) * 60;
    if (!validSubscriptionUrl(source)) {
      throw new ProfileError('url_invalid');
    }
    if (!Number.isSafeInteger(interval) || interval < 1) {
      throw new ProfileError('interval_invalid');
    }
    if (edit.baseUrl !== undefined && sub.url !== edit.baseUrl && sub.url !== source) {
      throw new ProfileError('conflict');
    }
    if (list.subscriptions.some((other: SubscriptionRecord): boolean => other.id !== sub.id && other.url === source)) {
      throw new ProfileError('link_exists');
    }
    sourceChanged = source !== sub.url;
    if (sourceChanged) {
      sub.url = source;
      sub.revision = newId('s');
    }
    sub.autoUpdate = edit.autoUpdate;
    sub.intervalMinutes = interval;
    sub.intervalHours = interval / 60;
  }
  record.name = name;
  record.nameEdited = true;
  return sourceChanged;
}

export async function saveProfileEdit(env: UpdateEnv, id: string, edit: ProfileEdit,
  shouldCommit: () => boolean): Promise<boolean> {
  const eligible = (): boolean => shouldCommit() && env.eligible?.() !== false;
  checkProfileCommit(eligible);
  if (edit.content === undefined) {
    return await withProfileStorage<boolean>(env.filesDir, async (): Promise<boolean> => {
      const list = await readListAsync(env.filesDir);
      const changed = applyMetadata(list, id, edit);
      await writeList(env.filesDir, list, eligible);
      return changed;
    });
  }
  return await withProfileTask<boolean>(env.filesDir, id, async (): Promise<boolean> => {
    const candidate = candidatePath(env.filesDir, id);
    try {
      await writeProfileText(candidate, edit.content ?? '', eligible);
      const change: ProfileCandidateChange = {
        expectedContentRevision: edit.baseContentRevision,
        mutate: (list: ProfileList): void => { applyMetadata(list, id, edit); }
      };
      await commitCandidate(env, id, candidate, eligible, change);
      return false;
    } finally {
      await removeProfileFile(candidate);
    }
  });
}

export async function saveProfileOrder(filesDir: string, ids: string[], shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  await withProfileStorage<void>(filesDir, async (): Promise<void> => {
    checkProfileCommit(shouldCommit);
    const list = await readListAsync(filesDir);
    const ordered: ProfileRecord[] = [];
    const seen = new Set<string>();
    for (const id of ids) {
      const profile = findProfile(list, id);
      if (profile !== undefined && !seen.has(id)) {
        ordered.push(profile);
        seen.add(id);
      }
    }
    for (const profile of list.profiles) {
      if (!seen.has(profile.id)) {
        ordered.push(profile);
      }
    }
    list.profiles = ordered;
    await writeList(filesDir, list, shouldCommit);
  });
}

export async function removeSavedProfile(filesDir: string, id: string, shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  await withProfileStorage<void>(filesDir, async (): Promise<void> => {
    checkProfileCommit(shouldCommit);
    const list = await readListAsync(filesDir);
    const record = findProfile(list, id);
    if (record === undefined) { return; }
    const oldList = await readOptionalText(listPath(filesDir));
    const paths = [yamlPath(filesDir, id), summaryPath(filesDir, id), selectedPath(filesDir, id)];
    if (record.subscription !== '') { paths.push(statePath(filesDir, record.subscription)); }
    const originals: Record<string, string | undefined> = {};
    for (const path of paths) { originals[path] = await readOptionalText(path); }
    list.profiles = list.profiles.filter((profile: ProfileRecord): boolean => profile.id !== id);
    if (record.subscription !== '') {
      list.subscriptions = list.subscriptions.filter((sub: SubscriptionRecord): boolean => sub.id !== record.subscription);
    }
    if (list.current === id) { list.current = list.profiles.length > 0 ? list.profiles[0].id : ''; }
    checkProfileCommit(shouldCommit);
    try {
      await writeList(filesDir, list, shouldCommit);
      for (const path of paths) {
        checkProfileCommit(shouldCommit);
        await removeProfileFile(path);
        checkProfileCommit(shouldCommit);
      }
    } catch (e) {
      for (const path of paths) {
        const original = originals[path];
        if (original !== undefined) { await writeProfileText(path, original); }
      }
      if (oldList !== undefined) { await writeProfileText(listPath(filesDir), oldList); }
      throw e as Error;
    }
  });
}

export async function readSourceText(filesDir: string, id: string): Promise<string> {
  try {
    return await fs.readText(yamlPath(filesDir, id));
  } catch (e) {
    throw new ProfileError('io');
  }
}
