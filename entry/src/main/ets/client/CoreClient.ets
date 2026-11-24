// UI-side control of the core: starts and stops ClashVpnAbility and talks to
// mihomo's external controller. The UI never loads libclash.so itself.
import { common, Want } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http, vpnExtension } from '@kit.NetworkKit';
import {
  CONTROLLER_ADDRESS, readRuntime, readRuntimeInstance, runtimeMayBeActive, RuntimeConfig, takeCoreError, writeRuntime
} from '../shared/Runtime';
import { RuntimeStatus } from './Controller';
import { readVpnNetworkSettings } from './VpnNetworkSettings';
import { withProfileStorage } from '../shared/profiles/Store';

// Generous until Geo data is bundled: the first start may download it.
const READY_TIMEOUT_MS = 30000;
const READY_POLL_MS = 200;

let pendingStart: Promise<RuntimeStatus> | undefined = undefined;
let hostGeneration: number = 0;

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
      typeof status.vpnCreated !== 'boolean' ||
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
  return runtime === undefined ? undefined : fetchCurrentStatus(context.filesDir, runtime.secret, 1000);
}

async function fetchCurrentStatus(filesDir: string, secret: string,
  timeoutMs: number): Promise<RuntimeStatus | undefined> {
  const generation = hostGeneration;
  const instance = await readRuntimeInstance(filesDir);
  const runtime = await readRuntime(filesDir);
  if (runtime?.secret !== secret || instance === undefined || instance.secret !== secret) {
    return undefined;
  }
  const status = await fetchStatus(secret, timeoutMs);
  const current = await readRuntimeInstance(filesDir);
  const latest = await readRuntime(filesDir);
  if (generation !== hostGeneration || secret !== latest?.secret ||
    instance?.secret !== current?.secret || instance?.instance !== current?.instance ||
    (current !== undefined && current.secret !== secret)) {
    return undefined;
  }
  return status;
}

export type CoreHostState = 'unknown' | 'stopped' | 'running';

export interface CoreHostSnapshot {
  state: CoreHostState;
  status?: RuntimeStatus;
}

/** 启动交接期间没有进程不等于停止，查询途中发生的启停也使旧证据失效。 */
export async function readCoreHostStatus(context: common.UIAbilityContext): Promise<CoreHostSnapshot> {
  const generation = hostGeneration;
  if (pendingStart !== undefined) {
    return { state: 'unknown' };
  }
  const active = await runtimeMayBeActive(context.filesDir);
  if (generation !== hostGeneration || pendingStart !== undefined) {
    return { state: 'unknown' };
  }
  if (!active) {
    return { state: 'stopped' };
  }
  const status = await probeCore(context);
  if (generation !== hostGeneration || pendingStart !== undefined) {
    return { state: 'unknown' };
  }
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
export function startCore(context: common.UIAbilityContext, mode: string,
  allowLan: boolean | undefined, isCurrent: () => boolean): Promise<RuntimeStatus> {
  if (pendingStart !== undefined) {
    return pendingStart.then((status: RuntimeStatus): RuntimeStatus => {
      if (!isCurrent()) {
        throw new CoreStartError('启动已取消', true);
      }
      return status;
    });
  }
  const generation = hostGeneration;
  const pending = performStartCore(context, mode, allowLan,
    (): boolean => generation === hostGeneration && isCurrent());
  pendingStart = pending;
  return pending.finally((): void => {
    if (pendingStart === pending) {
      pendingStart = undefined;
    }
  });
}

async function performStartCore(context: common.UIAbilityContext, mode: string,
  allowLan: boolean | undefined, isCurrent: () => boolean): Promise<RuntimeStatus> {
  let extensionStarted = false;
  try {
    const filesDir = context.filesDir;
    if (!isCurrent()) {
      throw new Error('启动已取消');
    }
    const generation = hostGeneration;
    if (await runtimeMayBeActive(filesDir)) {
      const existing = await probeCore(context);
      if (generation !== hostGeneration || !isCurrent()) {
        throw new Error('启动已取消');
      }
      if (existing?.running === true) {
        return existing;
      }
      throw new Error('尚未确认代理状态，请先确认停止');
    }
    if (generation !== hostGeneration || !isCurrent()) {
      throw new Error('启动已取消');
    }
    const secret = randomSecret();
    await withProfileStorage<void>(filesDir, async (): Promise<void> => {
      if (!isCurrent()) {
        throw new Error('启动已取消');
      }
      if (await runtimeMayBeActive(filesDir)) {
        throw new Error('代理宿主已变化，请重试');
      }
      if (!isCurrent()) {
        throw new Error('启动已取消');
      }
      await takeCoreError(filesDir);
      await writeRuntime(filesDir, { secret: secret, stack: 'gvisor', mode: mode, allowLan: allowLan,
        vpnIntent: 'stopped', vpnOperation: randomSecret() });
    });

    if (!isCurrent()) {
      throw new Error('启动已取消');
    }
    // 系统 Promise 已报告授权结果；部分固件回收 VpnObserver 时会使 UI 进程崩溃。
    try {
      await vpnExtension.startVpnExtensionAbility(vpnWant(context));
    } catch (error) {
      if (error === undefined) {
        throw new Error('vpn_authorization_denied');
      }
      throw error as Error;
    }
    extensionStarted = true;
    if (!isCurrent()) {
      if ((await readRuntime(filesDir))?.secret === secret) {
        await stopRuntimeResources(context);
      }
      throw new Error('启动已取消');
    }

    const deadline = Date.now() + READY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (!isCurrent()) {
        await stopRuntimeResources(context);
        throw new Error('启动已取消');
      }
      const error = await takeCoreError(filesDir);
      if (error !== undefined) {
        throw new Error(error);
      }
      const status = await fetchCurrentStatus(filesDir, secret, READY_POLL_MS);
      if (!isCurrent()) {
        await stopRuntimeResources(context);
        throw new Error('启动已取消');
      }
      if (status?.running === true) {
        return status;
      }
      await sleep(READY_POLL_MS);
    }
    await stopRuntimeResources(context);
    throw new Error('代理启动超时，请重试');
  } catch (error) {
    throw new CoreStartError((error as Error).message, extensionStarted);
  }
}

interface VpnCommandBody {
  bootId: string;
  operationId: string;
  profile?: string;
  configRevision?: number;
}

export async function connectVpn(context: common.UIAbilityContext, status: RuntimeStatus,
  isCurrent: () => boolean): Promise<RuntimeStatus> {
  if (status.profile === '') {
    throw new Error('vpn_no_profile');
  }
  return changeVpn(context, status, true, isCurrent);
}

export async function disconnectVpn(context: common.UIAbilityContext, status: RuntimeStatus,
  isCurrent: () => boolean): Promise<RuntimeStatus> {
  return changeVpn(context, status, false, isCurrent);
}

async function changeVpn(context: common.UIAbilityContext, status: RuntimeStatus, connect: boolean,
  isCurrent: () => boolean): Promise<RuntimeStatus> {
  const generation = hostGeneration;
  const filesDir = context.filesDir;
  const instance = await readRuntimeInstance(filesDir);
  const runtime = await readRuntime(filesDir);
  if (runtime === undefined || instance === undefined || instance.secret !== runtime.secret || !isCurrent()) {
    throw new Error('代理实例已变化，请重试');
  }
  const network = connect ? await readVpnNetworkSettings(context) : undefined;
  const operation = randomSecret();
  const current = async (): Promise<boolean> => {
    const latest = await readRuntime(filesDir);
    const proof = await readRuntimeInstance(filesDir);
    return isCurrent() && generation === hostGeneration && latest?.secret === runtime.secret &&
      latest.vpnOperation === operation && proof?.secret === instance.secret &&
      proof?.instance === instance.instance;
  };
  await withProfileStorage<void>(filesDir, async (): Promise<void> => {
    const latest = await readRuntime(filesDir);
    const proof = await readRuntimeInstance(filesDir);
    if (!isCurrent() || generation !== hostGeneration || latest?.secret !== runtime.secret ||
      proof?.instance !== instance.instance || proof?.secret !== runtime.secret) {
      throw new Error('代理实例已变化，请重试');
    }
    latest.vpnIntent = connect ? 'started' : 'stopped';
    latest.vpnOperation = operation;
    if (network !== undefined) {
      latest.network = network;
    }
    await writeRuntime(filesDir, latest);
  });
  if (!await current()) {
    throw new Error('VPN 操作尚未确认，请重试');
  }
  const body: VpnCommandBody = { bootId: status.bootId, operationId: operation };
  if (connect) {
    body.profile = status.profile;
    body.configRevision = status.configRevision;
  }
  const request = http.createHttp();
  let failure = 'VPN 操作尚未确认，请重试';
  let rejected = false;
  try {
    const response = await request.request(
      `http://${CONTROLLER_ADDRESS}/arkclash/vpn/${connect ? 'connect' : 'disconnect'}`, {
        method: http.RequestMethod.POST,
        header: { 'Authorization': `Bearer ${runtime.secret}`, 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body), connectTimeout: 3000, readTimeout: 3000,
        expectDataType: http.HttpDataType.STRING
      });
    if (response.responseCode !== 200) {
      rejected = true;
      const error = JSON.parse(response.result as string) as Record<string, string>;
      failure = error.message ?? failure;
    }
  } catch (_error) {
    // A transport timeout cannot cancel native work; authenticate bounded readback.
  } finally {
    request.destroy();
  }
  if (rejected) {
    throw new Error(failure);
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && await current()) {
    const snapshot = await fetchCurrentStatus(filesDir, runtime.secret, READY_POLL_MS);
    if (!await current()) {
      break;
    }
    if (snapshot !== undefined && (snapshot.bootId !== status.bootId ||
      (connect && snapshot.configRevision !== status.configRevision))) {
      throw new Error('代理配置已变化，请重试');
    }
    if (snapshot?.running === true && (connect ?
      snapshot.intent === 'started' && snapshot.forward === 'running' &&
        snapshot.vpnCreated && snapshot.tunAttached && snapshot.listenersOpen :
      snapshot.intent === 'stopped' && snapshot.forward === 'stopped' &&
        !snapshot.vpnCreated && !snapshot.tunAttached && !snapshot.listenersOpen)) {
      return snapshot;
    }
    await sleep(READY_POLL_MS);
  }
  throw new Error(failure);
}

/** 连接中改了模式或局域网代理时调用，VPN 进程被系统重新拉起时也能用上（secret 不变）。 */
export async function updateRuntimeOptions(filesDir: string, mode: string, allowLan: boolean | undefined): Promise<void> {
  await withProfileStorage<void>(filesDir, async (): Promise<void> => {
    const runtime = await readRuntime(filesDir);
    if (runtime === undefined) {
      return;
    }
    runtime.mode = mode;
    runtime.allowLan = allowLan;
    await writeRuntime(filesDir, runtime);
  });
}

export async function stopCore(context: common.UIAbilityContext): Promise<void> {
  ++hostGeneration;
  const pending = pendingStart;
  let failure: Error | undefined = undefined;
  try {
    await stopRuntimeResources(context);
  } catch (error) {
    failure = error as Error;
  }
  await pending?.catch((): void => {});
  if (!await runtimeMayBeActive(context.filesDir)) {
    return;
  }
  throw failure ?? new Error('尚未确认代理已停止，请重试');
}

async function stopRuntimeResources(context: common.UIAbilityContext): Promise<void> {
  let stopError: Error | undefined = undefined;
  try {
    await vpnExtension.stopVpnExtensionAbility(vpnWant(context));
  } catch (error) {
    stopError = error as Error;
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (!await runtimeMayBeActive(context.filesDir)) {
      return;
    }
    if (stopError !== undefined) {
      throw stopError;
    }
    await sleep(READY_POLL_MS);
  }
  throw new Error('尚未确认代理已停止，请重试');
}
