// UI-side control of the core: starts and stops ClashVpnAbility and talks to
// mihomo's external controller. The UI never loads libclash.so itself.
import { common, Want } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http, vpnExtension } from '@kit.NetworkKit';
import {
  CONTROLLER_ADDRESS, readRuntime, runtimeMayBeActive, RuntimeConfig, takeCoreError, wasRuntimeStopped, writeRuntime
} from '../shared/Runtime';
import { RuntimeStatus } from './Controller';
import { withProfileStorage } from '../shared/profiles/Store';

// Generous until Geo data is bundled: the first start may download it.
const READY_TIMEOUT_MS = 30000;
const READY_POLL_MS = 200;

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

async function fetchStatus(secret: string, timeoutMs: number): Promise<RuntimeStatus | undefined> {
  const request = http.createHttp();
  try {
    const header: Record<string, string> = { 'Authorization': `Bearer ${secret}` };
    const response = await request.request(`http://${CONTROLLER_ADDRESS}/arkclash/status`, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200) {
      return undefined;
    }
    const status = JSON.parse(response.result as string) as RuntimeStatus;
    if (typeof status.running !== 'boolean' || typeof status.tunAttached !== 'boolean' ||
      typeof status.listenersOpen !== 'boolean' || typeof status.profile !== 'string' ||
      typeof status.bootId !== 'string' || status.bootId === '' ||
      !Number.isInteger(status.revision) || !Number.isInteger(status.configRevision)) {
      return undefined;
    }
    return status;
  } catch (e) {
    return undefined;
  } finally {
    request.destroy();
  }
}

/** 只读取核心提交后的运行事实，controller 可达不等于转发已就绪。 */
export async function probeCore(context: common.UIAbilityContext): Promise<RuntimeStatus | undefined> {
  const runtime = await readRuntime(context.filesDir);
  if (runtime === undefined) {
    return undefined;
  }
  return fetchStatus(runtime.secret, 1000);
}

export type CoreHostState = 'unknown' | 'stopped' | 'running';

export interface CoreHostSnapshot {
  state: CoreHostState;
  status?: RuntimeStatus;
}

/** 实例文件先于资源创建；没有未清理实例时不等待已关闭的 controller 超时。 */
export async function readCoreHostStatus(context: common.UIAbilityContext): Promise<CoreHostSnapshot> {
  if (!await runtimeMayBeActive(context.filesDir)) {
    return { state: 'stopped' };
  }
  const status = await probeCore(context);
  return status?.running === true ? { state: 'running', status: status } : { state: 'unknown' };
}

export class CoreStartError extends Error {
  extensionStarted: boolean;

  constructor(message: string, extensionStarted: boolean) {
    super(message);
    this.extensionStarted = extensionStarted;
  }
}

/** 一次有界启动；取消代次不会将晚到的成功交给界面。 */
export async function startCore(context: common.UIAbilityContext, mode: string,
  allowLan: boolean | undefined, isCurrent: () => boolean): Promise<RuntimeStatus> {
  let extensionStarted = false;
  try {
    const filesDir = context.filesDir;
    if (!isCurrent()) {
      throw new Error('启动已取消');
    }
    const secret = randomSecret();
    await withProfileStorage<void>(filesDir, async (): Promise<void> => {
      if (!isCurrent()) {
        throw new Error('启动已取消');
      }
      await takeCoreError(filesDir);
      await writeRuntime(filesDir, { secret: secret, stack: 'gvisor', mode: mode, allowLan: allowLan });
    });

    if (!isCurrent()) {
      throw new Error('启动已取消');
    }
    // Shows the system authorization dialog the first time.
    await vpnExtension.startVpnExtensionAbility(vpnWant(context));
    extensionStarted = true;
    if (!isCurrent()) {
      await stopCore(context);
      throw new Error('启动已取消');
    }

    const deadline = Date.now() + READY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (!isCurrent()) {
        await stopCore(context);
        throw new Error('启动已取消');
      }
      const error = await takeCoreError(filesDir);
      if (error !== undefined) {
        throw new Error(error);
      }
      const status = await fetchStatus(secret, READY_POLL_MS);
      if (status?.running === true && status.forward === 'running' && status.tunAttached &&
        status.profile !== '') {
        return status;
      }
      await sleep(READY_POLL_MS);
    }
    await stopCore(context);
    throw new Error('代理启动超时，请重试');
  } catch (error) {
    throw new CoreStartError((error as Error).message, extensionStarted);
  }
}

/** 连接中改了模式或局域网代理时调用，VPN 进程被系统重新拉起时也能用上（secret 不变）。 */
export async function updateRuntimeOptions(filesDir: string, mode: string, allowLan: boolean | undefined): Promise<void> {
  const runtime = await readRuntime(filesDir);
  if (runtime === undefined) {
    return;
  }
  const next: RuntimeConfig = { secret: runtime.secret, stack: runtime.stack, mode: mode, allowLan: allowLan };
  await writeRuntime(filesDir, next);
}

export async function stopCore(context: common.UIAbilityContext): Promise<void> {
  const secret = (await readRuntime(context.filesDir))?.secret ?? '';
  let stopError: Error | undefined = undefined;
  try {
    await vpnExtension.stopVpnExtensionAbility(vpnWant(context));
  } catch (error) {
    stopError = error as Error;
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (await wasRuntimeStopped(context.filesDir, secret)) {
      return;
    }
    if (stopError !== undefined) {
      throw stopError;
    }
    await sleep(READY_POLL_MS);
  }
  throw new Error('尚未确认代理已停止，请重试');
}
