// State shared by the UI process and ClashVpnAbility through the app's files
// dir. The extension may also be started by the system without our Want
// parameters, so everything it needs lives on disk.
import { fileIo as fs } from '@kit.CoreFileKit';
import { readText, writeText, writeTextAsync } from './Files';

export const CONTROLLER_ADDRESS = '127.0.0.1:19090';

/** 界面写，VPN 进程在启动时读。要用哪份配置不在这里，VPN 进程从配置列表里读（ADR-0010）。 */
export interface RuntimeConfig {
  secret: string;
  stack: string;
  mode: string; // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
  allowLan?: boolean; // 没有 = 用配置里的值
}

function runtimePath(filesDir: string): string {
  return `${filesDir}/runtime.json`;
}

function errorPath(filesDir: string): string {
  return `${filesDir}/core_error.txt`;
}

interface RuntimeStopReceipt {
  secret: string;
  instance: string;
}

export function beginRuntimeInstance(filesDir: string, secret: string, instance: string): Promise<void> {
  const active: RuntimeStopReceipt = { secret: secret, instance: instance };
  return writeTextAsync(`${filesDir}/runtime-instance.json`, JSON.stringify(active));
}

export function writeRuntimeStopped(filesDir: string, secret: string, instance: string): Promise<void> {
  const receipt: RuntimeStopReceipt = { secret: secret, instance: instance };
  return writeTextAsync(`${filesDir}/runtime-stopped.json`, JSON.stringify(receipt));
}

export async function wasRuntimeStopped(filesDir: string, secret: string): Promise<boolean> {
  if (secret === '') {
    return false;
  }
  const texts = await Promise.all<string | undefined>([
    readText(`${filesDir}/runtime-instance.json`), readText(`${filesDir}/runtime-stopped.json`)
  ]);
  if (texts[0] === undefined || texts[1] === undefined) {
    return false;
  }
  try {
    const active = JSON.parse(texts[0]) as RuntimeStopReceipt;
    const receipt = JSON.parse(texts[1]) as RuntimeStopReceipt;
    return active.secret === secret && receipt.secret === secret &&
      typeof active.instance === 'string' && active.instance !== '' && receipt.instance === active.instance;
  } catch (error) {
    return false;
  }
}

/** 没有当前实例的清理回执时，不能因 controller 失联就转为离线写入。 */
export async function runtimeMayBeActive(filesDir: string): Promise<boolean> {
  const path = `${filesDir}/runtime-instance.json`;
  const text = await readText(path);
  if (text === undefined) {
    return fs.access(path);
  }
  try {
    const active = JSON.parse(text) as RuntimeStopReceipt;
    if (typeof active.secret !== 'string' || active.secret === '' ||
      typeof active.instance !== 'string' || active.instance === '') {
      return true;
    }
    return !await wasRuntimeStopped(filesDir, active.secret);
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
