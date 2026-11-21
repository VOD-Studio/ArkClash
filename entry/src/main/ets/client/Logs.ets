import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { ControllerSocket, ControllerSocketState } from './ControllerSocket';

export const LOG_LIMIT = 5000;

export interface LogRecord {
  id: string;
  time: number;
  level: string;
  message: string;
}

export interface LogFrame {
  type: string;
  bootId: string;
  configRevision: number;
  sessionId: string;
  seq: number;
  kind: string;
  dropped: number;
  evicted: number;
  logs: LogRecord[];
}

export function logStream(bootId: string, revision: number, onFrame: (frame: LogFrame) => void,
  onState: (state: ControllerSocketState) => void): ControllerSocket {
  const path = `/arkclash/diagnostics/logs?expectedBootId=${encodeURIComponent(bootId)}&expectedConfigRevision=${revision}`;
  const socket = new ControllerSocket(path, (text: string): void => {
    try {
      const frame = JSON.parse(text) as LogFrame;
      if (frame.type !== 'logs' || frame.bootId !== bootId || frame.configRevision !== revision ||
        !Number.isSafeInteger(frame.seq) || frame.seq <= 0 || frame.sessionId.length === 0 ||
        !['snapshot', 'delta', 'reset'].includes(frame.kind) ||
        !Array.isArray(frame.logs) || frame.logs.length > LOG_LIMIT) {
        throw new Error('invalid_log_frame');
      }
      onFrame(frame);
    } catch (_error) {
      socket.fail('invalid_log_frame');
    }
  }, onState);
  return socket;
}

export async function exportLogs(context: common.UIAbilityContext, records: LogRecord[]): Promise<boolean> {
  const options = new picker.DocumentSaveOptions();
  const day = new Date().toISOString().slice(0, 10);
  options.newFileNames = [`ArkClash-${day}.log`];
  const targets = await new picker.DocumentViewPicker(context).save(options);
  if (targets.length === 0) { return false; }
  const file = await fs.open(targets[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    try {
      for (let start = 0; start < records.length; start += 64) {
        const chunk = records.slice(start, start + 64).map((row: LogRecord): string =>
          `${new Date(row.time).toISOString()} [${row.level}] ${row.message}\n`).join('');
        const written = await fs.write(file.fd, chunk, { encoding: 'utf-8' });
        if (written !== new util.TextEncoder().encodeInto(chunk).byteLength) { throw new Error('log_export_incomplete'); }
      }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
  } catch (error) {
    try { await fs.unlink(targets[0]); } catch (_cleanup) {}
    throw error as Error;
  }
  return true;
}
