// 两个进程共用的文件读写。写文件一律先写临时文件再改名替换，另一个进程读到的要么是旧的
// 完整文件，要么是新的完整文件（#35）。
import { fileIo as fs } from '@kit.CoreFileKit';

export function hasFile(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

export function ensureDir(path: string): void {
  if (!hasFile(path)) {
    fs.mkdirSync(path, true);
  }
}

// 两个进程可能同时写同一个文件，临时文件名不能相同，否则两边会写进同一个临时文件。
function tempPath(path: string): string {
  return `${path}.${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}.tmp`;
}

/** 同步版，只用于很小的文件（runtime.json 等）。 */
export function writeText(path: string, text: string): void {
  const tmp = tempPath(path);
  const file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
  fs.renameSync(tmp, path);
}

export async function writeTextAsync(path: string, text: string): Promise<void> {
  const tmp = tempPath(path);
  const file = await fs.open(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, text);
  } finally {
    await fs.close(file);
  }
  await fs.rename(tmp, path);
}

/** 文件不存在或读不了时返回 undefined。 */
export function readTextSync(path: string): string | undefined {
  try {
    return fs.readTextSync(path);
  } catch (e) {
    return undefined;
  }
}

export async function readText(path: string): Promise<string | undefined> {
  try {
    return await fs.readText(path);
  } catch (e) {
    return undefined;
  }
}

/** 删除文件；不存在时什么都不做。 */
export async function removeFile(path: string): Promise<void> {
  try {
    await fs.unlink(path);
  } catch (e) {
    // 文件本来就不在
  }
}

export async function moveFile(from: string, to: string): Promise<void> {
  await fs.rename(from, to);
}

export async function listDir(path: string): Promise<string[]> {
  try {
    return await fs.listFile(path);
  } catch (e) {
    return [];
  }
}
