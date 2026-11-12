// State shared by the UI process and ClashVpnAbility through the app's files
// dir. The extension may also be started by the system without our Want
// parameters, so everything it needs lives on disk.
import { fileIo as fs } from '@kit.CoreFileKit';
import { hasFile, readTextSync, writeText } from './Files';

export const CONTROLLER_ADDRESS = '127.0.0.1:19090';

/** 界面写，VPN 进程在启动时读。要用哪份配置不在这里，VPN 进程从配置列表里读（ADR-0010）。 */
export interface RuntimeConfig {
  secret: string;
  stack: string;
  mode: string; // 'rule' | 'global' | 'direct'，空串 = 用配置里的值
  allowLan?: boolean; // 没有 = 用配置里的值
  standby?: boolean; // 实验：只加载内核不建隧道
}

function runtimePath(filesDir: string): string {
  return `${filesDir}/runtime.json`;
}

function errorPath(filesDir: string): string {
  return `${filesDir}/core_error.txt`;
}

export function writeRuntime(filesDir: string, config: RuntimeConfig): void {
  writeText(runtimePath(filesDir), JSON.stringify(config));
}

export function readRuntime(filesDir: string): RuntimeConfig | undefined {
  const text = readTextSync(runtimePath(filesDir));
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

export function takeCoreError(filesDir: string): string | undefined {
  const path = errorPath(filesDir);
  if (!hasFile(path)) {
    return undefined;
  }
  const message = readTextSync(path) ?? '';
  fs.unlinkSync(path);
  return message;
}
