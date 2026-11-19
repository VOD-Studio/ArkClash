import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  MAX_TUN_MTU, minTunMtu, TUN_CONGESTION_CONTROLLERS, TUN_STACKS, VpnNetworkSettings, vpnRoutePrefixes
} from '../shared/VpnNetwork';

const STORE = 'vpn_network';
const KEY = 'settings';
let pendingSave: Promise<void> = Promise.resolve();

export async function readVpnNetworkSettings(context: common.UIAbilityContext): Promise<VpnNetworkSettings> {
  await pendingSave;
  const store = await preferences.getPreferences(context, { name: STORE });
  const text = await store.get(KEY, '') as string;
  const settings = new VpnNetworkSettings();
  if (text === '') {
    return settings;
  }
  const saved = JSON.parse(text) as VpnNetworkSettings;
  settings.stack = saved.stack ?? settings.stack;
  settings.ipv6 = saved.ipv6 ?? settings.ipv6;
  settings.dnsHijacking = saved.dnsHijacking ?? settings.dnsHijacking;
  settings.mtu = saved.mtu ?? settings.mtu;
  settings.congestionController = saved.congestionController ?? settings.congestionController;
  settings.bypassPrivateRoute = saved.bypassPrivateRoute ?? settings.bypassPrivateRoute;
  settings.routeAddress = saved.routeAddress ?? settings.routeAddress;
  settings.routeExcludeAddress = saved.routeExcludeAddress ?? settings.routeExcludeAddress;
  return settings;
}

export function saveVpnNetworkSettings(context: common.UIAbilityContext, settings: VpnNetworkSettings): Promise<void> {
  const save = pendingSave.then(async (): Promise<void> => {
    if (!Number.isInteger(settings.mtu) || settings.mtu < minTunMtu(settings.ipv6) || settings.mtu > MAX_TUN_MTU) {
      throw new Error('invalid_mtu');
    }
    if (!TUN_STACKS.includes(settings.stack) || !TUN_CONGESTION_CONTROLLERS.includes(settings.congestionController)) {
      throw new Error('invalid_option');
    }
    vpnRoutePrefixes(settings);
    const store = await preferences.getPreferences(context, { name: STORE });
    const previous = await store.get(KEY, '');
    await store.put(KEY, JSON.stringify(settings));
    try {
      await store.flush();
    } catch (error) {
      await store.put(KEY, previous);
      throw error as Error;
    }
  });
  pendingSave = save.catch((): void => {});
  return save;
}
