// UI-side control of the core: starts and stops ClashVpnAbility and talks to
// mihomo's external controller. The UI never loads libclash.so itself.
import { common, Want } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http, vpnExtension } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime, RuntimeConfig, takeCoreError, writeRuntime } from '../shared/Runtime';

// Generous until Geo data is bundled: the first start may download it.
const READY_TIMEOUT_MS = 30000;
const READY_POLL_MS = 200;

interface VersionResponse {
  version: string;
}

function vpnWant(context: common.UIAbilityContext): Want {
  return { bundleName: context.applicationInfo.name, abilityName: 'ClashVpnAbility' };
}

function randomSecret(): string {
  const bytes = cryptoFramework.createRandom().generateRandomSync(16).data;
  let hex = '';
  bytes.forEach((b: number) => {
    hex += b.toString(16).padStart(2, '0');
  });
  return hex;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function fetchVersion(secret: string, timeoutMs: number): Promise<string | undefined> {
  const request = http.createHttp();
  try {
    const header: Record<string, string> = { 'Authorization': `Bearer ${secret}` };
    const response = await request.request(`http://${CONTROLLER_ADDRESS}/version`, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200) {
      return undefined;
    }
    return (JSON.parse(response.result as string) as VersionResponse).version;
  } catch (e) {
    return undefined;
  } finally {
    request.destroy();
  }
}

/** Returns the running core's version, or undefined if it is not running. */
export function probeCore(context: common.UIAbilityContext): Promise<string | undefined> {
  const runtime = readRuntime(context.filesDir);
  if (runtime === undefined) {
    return Promise.resolve(undefined);
  }
  return fetchVersion(runtime.secret, 1000);
}

/**
 * 启动 VPN，controller 能应答后返回内核版本。用哪份配置由 VPN 进程从配置列表读；mode 为空串、
 * allowLan 为 undefined 时用配置里的值。
 */
export async function startCore(context: common.UIAbilityContext, mode: string,
  allowLan: boolean | undefined): Promise<string> {
  const filesDir = context.filesDir;
  takeCoreError(filesDir);
  const secret = randomSecret();
  writeRuntime(filesDir, { secret: secret, stack: 'gvisor', mode: mode, allowLan: allowLan });

  // Shows the system authorization dialog the first time.
  await vpnExtension.startVpnExtensionAbility(vpnWant(context));

  const deadline = Date.now() + READY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const error = takeCoreError(filesDir);
    if (error !== undefined) {
      throw new Error(error);
    }
    const version = await fetchVersion(secret, READY_POLL_MS);
    if (version !== undefined) {
      return version;
    }
    await sleep(READY_POLL_MS);
  }
  throw new Error('core did not become ready in time, see hilog tag ArkClashCore');
}

/** 连接中改了模式或局域网代理时调用，VPN 进程被系统重新拉起时也能用上（secret 不变）。 */
export function updateRuntimeOptions(filesDir: string, mode: string, allowLan: boolean | undefined): void {
  const runtime = readRuntime(filesDir);
  if (runtime === undefined) {
    return;
  }
  const next: RuntimeConfig = { secret: runtime.secret, stack: runtime.stack, mode: mode, allowLan: allowLan };
  writeRuntime(filesDir, next);
}

export async function stopCore(context: common.UIAbilityContext): Promise<void> {
  await vpnExtension.stopVpnExtensionAbility(vpnWant(context));
}
