import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { normalizeVpnNetworkSettings, VpnNetworkSettings, VpnNetworkSnapshot } from '../shared/VpnNetwork';

const STORE = 'vpn_network';
const KEY = 'settings';
let pendingSave: Promise<void> = Promise.resolve();
let cachedSettings: VpnNetworkSettings | undefined = undefined;

export function peekVpnNetworkSettings(): VpnNetworkSettings | undefined {
  return cachedSettings !== undefined ? cachedSettings.copy() : undefined;
}

export function clearVpnNetworkSettingsCache(): void {
  cachedSettings = undefined;
}

export async function readVpnNetworkSettings(context: common.UIAbilityContext): Promise<VpnNetworkSettings> {
  await pendingSave;
  const store = await preferences.getPreferences(context, { name: STORE });
  const text = await store.get(KEY, '') as string;
  const own = context.applicationInfo.name;
  const settings = text === '' ? new VpnNetworkSettings() :
    normalizeVpnNetworkSettings(JSON.parse(text) as VpnNetworkSnapshot, own, false);
  cachedSettings = settings.copy();
  return settings;
}

export function saveVpnNetworkSettings(context: common.UIAbilityContext, settings: VpnNetworkSettings): Promise<void> {
  const save = pendingSave.then(async (): Promise<void> => {
    const normalized = normalizeVpnNetworkSettings(settings, context.applicationInfo.name, true);
    const store = await preferences.getPreferences(context, { name: STORE });
    const previous = await store.get(KEY, '');
    await store.put(KEY, JSON.stringify(normalized));
    try {
      await store.flush();
      cachedSettings = normalized.copy();
    } catch (error) {
      await store.put(KEY, previous);
      throw error as Error;
    }
  });
  pendingSave = save.catch((): void => {});
  return save;
}
