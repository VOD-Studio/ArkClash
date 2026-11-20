import { fileIo as fs } from '@kit.CoreFileKit';
import { GENERAL_SETTINGS_FILE, GeneralSettings, validGeneralUserAgent } from './GeneralSettingsModel';

export {
  GENERAL_SETTINGS_FILE, GENERAL_LEVELS, GENERAL_TIMEOUTS, defaultGeneralPorts, defaultGeneralSettings,
  checkedGeneralSettings
} from './GeneralSettingsModel';
export type { GeneralPorts, GeneralAuthentication, GeneralSettings } from './GeneralSettingsModel';

export async function generalUserAgent(filesDir: string): Promise<string | undefined> {
  if (filesDir === '') { return undefined; }
  try {
    const saved = JSON.parse(await fs.readText(`${filesDir}/${GENERAL_SETTINGS_FILE}`)) as GeneralSettings;
    return validGeneralUserAgent(saved.userAgent) && saved.userAgent !== '' ? saved.userAgent : undefined;
  } catch (_error) {
    return undefined;
  }
}
