import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { writeTextAsync } from '../shared/Files';
import { runtimeMayBeActive } from '../shared/Runtime';
import { withProfileStorage } from '../shared/profiles/Store';
import { call } from './Controller';
import { readCoreHostStatus } from './CoreClient';

export interface VersionedProfileSettings {
  revision: string;
}

interface ProfileSettingsRequest<T extends VersionedProfileSettings> {
  bootId: string;
  expectedRevision: string;
  settings: T;
}

export interface ProfileSettingsFile<T extends VersionedProfileSettings> {
  fileName: string;
  endpoint: string;
  errorPrefix: string;
  defaults: () => T;
  checked: (value: T) => T;
}

export async function readProfileSettings<T extends VersionedProfileSettings>(filesDir: string,
  storage: ProfileSettingsFile<T>): Promise<T> {
  let text: string;
  try {
    text = await fs.readText(`${filesDir}/${storage.fileName}`);
  } catch (error) {
    const code = (error as BusinessError).code;
    if (code === 13900002 || code === 2) {
      return storage.defaults();
    }
    throw new Error(`${storage.errorPrefix}_io`);
  }
  try {
    return storage.checked(JSON.parse(text) as T);
  } catch (_error) {
    throw new Error(`${storage.errorPrefix}_invalid`);
  }
}

export async function saveProfileSettings<T extends VersionedProfileSettings>(context: common.UIAbilityContext,
  storage: ProfileSettingsFile<T>, expectedRevision: string, value: T): Promise<T> {
  const filesDir = context.filesDir;
  const settings = storage.checked(value);
  const serialized = JSON.stringify(settings);
  // 保留 1 KiB 给请求外层字段。
  if (new util.TextEncoder().encodeInto(serialized).byteLength > 127 * 1024) {
    throw new Error(`${storage.errorPrefix}_invalid`);
  }
  const host = await readCoreHostStatus(context);
  if (host.state === 'running' && host.status !== undefined) {
    const request: ProfileSettingsRequest<T> = {
      bootId: host.status.bootId, expectedRevision: expectedRevision, settings: settings
    };
    try {
      await call(filesDir, http.RequestMethod.POST, storage.endpoint, JSON.stringify(request), 90000);
    } catch (error) {
      const committed = await readProfileSettings<T>(filesDir, storage).catch((): undefined => undefined);
      if (committed?.revision !== settings.revision) {
        throw error as Error;
      }
    }
    return settings;
  }
  if (host.state !== 'stopped') {
    throw new Error(`${storage.errorPrefix}_unavailable`);
  }
  return withProfileStorage<T>(filesDir, async (): Promise<T> => {
    if (await runtimeMayBeActive(filesDir) || (await readProfileSettings<T>(filesDir, storage)).revision !== expectedRevision) {
      throw new Error(`${storage.errorPrefix}_conflict`);
    }
    try {
      await writeTextAsync(`${filesDir}/${storage.fileName}`, serialized);
    } catch (_error) {
      throw new Error(`${storage.errorPrefix}_io`);
    }
    return settings;
  });
}
