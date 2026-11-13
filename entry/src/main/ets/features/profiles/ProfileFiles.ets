import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { hostOf } from '../../shared/profiles/Download';
import { ProfileError } from '../../shared/profiles/Errors';
import { analyze } from '../../shared/profiles/Summary';
import {
  candidatePath, checkProfileCommit, DEFAULT_INTERVAL_HOURS, DEFAULT_INTERVAL_MINUTES, ensureProfilesDir, listPath, newId,
  ProfileList, ProfileRecord, readOptionalText, removeProfileFile, statePath, summaryPath, withProfileStorage,
  writeList, writeProfileText, yamlPath
} from '../../shared/profiles/Store';

export function profileFileName(uri: string): string {
  const tail = uri.split('/').pop() ?? '';
  try {
    return decodeURIComponent(tail);
  } catch (e) {
    return tail;
  }
}

export async function pickProfileFile(context: common.UIAbilityContext): Promise<string | undefined> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  const uris = await new picker.DocumentViewPicker(context).select(options);
  return uris.length > 0 ? uris[0] : undefined;
}

export async function stageProfileUri(filesDir: string, profile: string, uri: string): Promise<string> {
  await ensureProfilesDir(filesDir);
  const candidate = candidatePath(filesDir, profile);
  try {
    const source = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(source.fd, candidate);
    } finally {
      await fs.close(source);
    }
    return candidate;
  } catch (e) {
    await removeProfileFile(candidate);
    throw new ProfileError('io');
  }
}

export async function readProfileFile(context: common.UIAbilityContext): Promise<string | undefined> {
  const uri = await pickProfileFile(context);
  if (uri === undefined) {
    return undefined;
  }
  const staged = await stageProfileUri(context.filesDir, newId('edit'), uri);
  try {
    return await fs.readText(staged);
  } finally {
    await removeProfileFile(staged);
  }
}

export async function exportProfileSource(context: common.UIAbilityContext, profile: string,
  name: string): Promise<void> {
  const filename = name.replace(new RegExp('[\\\\/]', 'g'), '_');
  const options = new picker.DocumentSaveOptions();
  options.newFileNames = [new RegExp('\\.(ya?ml|txt)$', 'i').test(filename) ? filename : `${filename}.yaml`];
  options.fileSuffixChoices = ['YAML|.yaml,.yml'];
  const destinations = await new picker.DocumentViewPicker(context).save(options);
  if (destinations.length === 0) {
    return;
  }
  const destination = await fs.open(destinations[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    const source = await fs.open(yamlPath(context.filesDir, profile), fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(source.fd, destination.fd);
    } finally {
      await fs.close(source);
    }
  } finally {
    await fs.close(destination);
  }
}

export async function migrateProfileLegacy(context: common.UIAbilityContext, shouldCommit: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  const filesDir = context.filesDir;
  const legacy = `${filesDir}/profiles/default.yaml`;
  await ensureProfilesDir(filesDir);
  if (await fs.access(listPath(filesDir)) || !(await fs.access(legacy))) {
    return;
  }
  const prefs = await preferences.getPreferences(context, { name: 'settings' });
  const source = await prefs.get('subscriptionUrl', '') as string;
  const label = await prefs.get('profileName', '') as string;
  const profile = newId('p');
  const subscription = source !== '' ? newId('s') : '';
  checkProfileCommit(shouldCommit);
  const candidate = await stageProfileUri(filesDir, profile, legacy);
  try {
    const result = await analyze(candidate);
    if (result.error !== '') {
      throw new ProfileError(result.error);
    }
    const record: ProfileRecord = { id: profile, name: label || hostOf(source) || 'default.yaml',
      nameEdited: label !== '', subscription: subscription, type: source === '' ? 'file' : 'url' };
    const list: ProfileList = { version: 1, current: profile, profiles: [record], subscriptions: [] };
    const updatedAt = await prefs.get('profileUpdatedAt', 0) as number;
    const usageText = await prefs.get('profileUsage', '') as string;
    await withProfileStorage<void>(filesDir, async (): Promise<void> => {
      if (await readOptionalText(listPath(filesDir)) !== undefined) {
        return;
      }
      checkProfileCommit(shouldCommit);
      try {
        if (subscription !== '') {
          list.subscriptions.push({ id: subscription, url: source, autoUpdate: true,
            intervalHours: DEFAULT_INTERVAL_HOURS, intervalMinutes: DEFAULT_INTERVAL_MINUTES });
          const usage = usageText !== '' ? JSON.parse(usageText) as Object : undefined;
          const state: Record<string, Object | undefined> = { 'updatedAt': updatedAt, 'usage': usage, 'failures': 0 };
          await writeProfileText(statePath(filesDir, subscription), JSON.stringify(state), shouldCommit);
        }
        await writeProfileText(summaryPath(filesDir, profile), result.summary, shouldCommit);
        checkProfileCommit(shouldCommit);
        await fs.rename(candidate, yamlPath(filesDir, profile));
        checkProfileCommit(shouldCommit);
        await writeList(filesDir, list, shouldCommit);
      } catch (e) {
        await removeProfileFile(yamlPath(filesDir, profile));
        await removeProfileFile(summaryPath(filesDir, profile));
        if (subscription !== '') { await removeProfileFile(statePath(filesDir, subscription)); }
        throw e as Error;
      }
    });
    // 旧文件与旧 preferences 保留到专门迁移功能接管，失败不会使旧配置消失。
  } finally {
    await removeProfileFile(candidate);
  }
}
