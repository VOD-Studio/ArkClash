// State shared by the UI process and ClashVpnAbility through the app's files
// dir. The extension may also be started by the system without our Want
// parameters, so everything it needs lives on disk.
import { fileIo as fs } from '@kit.CoreFileKit';

export const CONTROLLER_ADDRESS = '127.0.0.1:19090';

export interface RuntimeConfig {
  configPath: string;
  secret: string;
  stack: string;
}

export function profilePath(filesDir: string): string {
  return `${filesDir}/profiles/default.yaml`;
}

export function hasFile(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

export function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
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
  if (!hasFile(runtimePath(filesDir))) {
    return undefined;
  }
  return JSON.parse(fs.readTextSync(runtimePath(filesDir))) as RuntimeConfig;
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
  const message = fs.readTextSync(path);
  fs.unlinkSync(path);
  return message;
}
