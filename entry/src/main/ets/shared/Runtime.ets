// State shared by the UI process and ClashVpnAbility through the app's files
// dir. The extension may also be started by the system without our Want
// parameters, so everything it needs lives on disk.
import { appManager } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { readText, writeText, writeTextAsync } from './Files';
import { VpnNetworkSettings } from './VpnNetwork';

export const CONTROLLER_ADDRESS = '127.0.0.1:19090';
// 界面绑定扩展时携带的 Want 参数。扩展若因绑定被系统拉起，不能当作一次启动（ADR-0038）。
export const HOST_BINDING_PARAM = 'arkclashHostBinding';

/** 启动设置与转发意图在短锁内提交；扩展新实例复位意图，当前配置仍以配置列表为准。 */
export interface RuntimeConfig {
  secret: string;
  stack: string;
  network?: VpnNetworkSettings;
  mode: string; // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
  allowLan?: boolean; // 没有 = 用配置里的值
  vpnIntent: 'started' | 'stopped';
  vpnOperation: string;
}

function runtimePath(filesDir: string): string {
  return `${filesDir}/runtime.json`;
}

function errorPath(filesDir: string): string {
  return `${filesDir}/core_error.txt`;
}

export interface RuntimeInstance {
  secret: string;
  instance: string;
}

export async function readRuntimeInstance(filesDir: string): Promise<RuntimeInstance | undefined> {
  const text = await readText(`${filesDir}/runtime-instance.json`);
  if (text === undefined) {
    return undefined;
  }
  const active = JSON.parse(text) as RuntimeInstance;
  if (typeof active.secret !== 'string' || active.secret === '' ||
    typeof active.instance !== 'string' || active.instance === '') {
    throw new Error('代理实例信息无效，请重试');
  }
  return active;
}

export function beginRuntimeInstance(filesDir: string, secret: string, instance: string): Promise<void> {
  const active: RuntimeInstance = { secret: secret, instance: instance };
  return writeTextAsync(`${filesDir}/runtime-instance.json`, JSON.stringify(active));
}

export function writeRuntimeStopped(filesDir: string, secret: string, instance: string): Promise<void> {
  const receipt: RuntimeInstance = { secret: secret, instance: instance };
  return writeTextAsync(`${filesDir}/runtime-stopped.json`, JSON.stringify(receipt));
}

export async function wasRuntimeStopped(filesDir: string, secret: string): Promise<boolean> {
  if (typeof secret !== 'string' || secret === '') {
    return false;
  }
  const texts = await Promise.all<string | undefined>([
    readText(`${filesDir}/runtime-instance.json`), readText(`${filesDir}/runtime-stopped.json`)
  ]);
  if (texts[0] === undefined || texts[1] === undefined) {
    return false;
  }
  try {
    const active = JSON.parse(texts[0]) as RuntimeInstance;
    const receipt = JSON.parse(texts[1]) as RuntimeInstance;
    return active.secret === secret && receipt.secret === secret &&
      typeof active.instance === 'string' && active.instance !== '' && receipt.instance === active.instance;
  } catch (error) {
    return false;
  }
}

/** 只有清理回执或系统确认除调用方外没有本应用进程，才允许离线写入。仅供 UI 进程调用。 */
export async function runtimeMayBeActive(filesDir: string): Promise<boolean> {
  const path = `${filesDir}/runtime-instance.json`;
  const before = await readText(path);
  const config = await readText(runtimePath(filesDir));
  if (before !== undefined) {
    try {
      const active = JSON.parse(before) as RuntimeInstance;
      const runtime = config === undefined ? undefined : JSON.parse(config) as RuntimeConfig;
      if (runtime?.secret === active.secret && await wasRuntimeStopped(filesDir, active.secret)) {
        return before !== await readText(path) || config !== await readText(runtimePath(filesDir));
      }
    } catch (_error) {
      // 损坏或旧版本的实例文件仍可通过系统进程事实恢复，不能直接删除。
    }
  }
  try {
    const processes = await appManager.getRunningProcessInformation();
    // 本模块只能从 UI 查询。其他本应用进程一律保守视为可能持有 VPN，不猜系统进程名。
    if (!processes.some((info: appManager.ProcessInformation): boolean => info.pid === process.pid) ||
      processes.some((info: appManager.ProcessInformation): boolean => info.pid !== process.pid)) {
      return true;
    }
    if (before !== await readText(path) || config !== await readText(runtimePath(filesDir))) {
      return true;
    }
    return before === undefined && await fs.access(path);
  } catch (_error) {
    return true;
  }
}

export function writeRuntime(filesDir: string, config: RuntimeConfig): Promise<void> {
  return writeTextAsync(runtimePath(filesDir), JSON.stringify(config));
}

export async function readRuntime(filesDir: string): Promise<RuntimeConfig | undefined> {
  const text = await readText(runtimePath(filesDir));
  if (text === undefined) {
    return undefined;
  }
  const config = JSON.parse(text) as RuntimeConfig;
  // 0.3.0 写的 runtime.json 没有 mode。
  if (typeof config.mode !== 'string') {
    config.mode = '';
  }
  if (config.vpnIntent !== 'started' && config.vpnIntent !== 'stopped') {
    config.vpnIntent = 'stopped';
  }
  if (typeof config.vpnOperation !== 'string' || config.vpnOperation === '') {
    config.vpnOperation = '';
    config.vpnIntent = 'stopped';
  }
  return config;
}

/** Written by ClashVpnAbility when the core fails to start, read by the UI. */
export function writeCoreError(filesDir: string, message: string): void {
  writeText(errorPath(filesDir), message);
}

export async function takeCoreError(filesDir: string): Promise<string | undefined> {
  const path = errorPath(filesDir);
  const message = await readText(path);
  if (message === undefined) {
    return undefined;
  }
  await fs.unlink(path);
  return message;
}
