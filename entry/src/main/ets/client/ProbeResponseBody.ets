import { util } from '@kit.ArkTS';
import { ProbeBodyMode, RoutedProbeError } from './ProbeProtocol';

const CHUNK_BYTES: number = 32 * 1024;
const EMPTY_BYTES: Uint8Array = new Uint8Array(0);

export class ProbeResponseBody {
  private mode: ProbeBodyMode;
  private limit: number;
  private received: number = 0;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private chunks: string[] = [];
  private tail: string = '';
  private evidence: string = '';
  private pattern?: RegExp;
  private finished: boolean = false;

  constructor(mode: ProbeBodyMode, scanPattern: string = '') {
    this.mode = mode;
    this.limit = mode === 'small' ? 16 * 1024 : mode === 'html' ? 512 * 1024 :
      mode === 'scan' ? 8 * 1024 * 1024 : mode === 'json' ? 64 * 1024 : 0;
    if (mode === 'scan') {
      if (scanPattern === '' || scanPattern.length > 512) { throw new RoutedProbeError('invalidResponse'); }
      this.pattern = new RegExp(scanPattern);
    }
  }

  append(data: ArrayBuffer): boolean {
    if (this.finished || this.mode === 'none') { return true; }
    if (this.mode === 'json' && data.byteLength > this.limit - this.received) {
      throw new RoutedProbeError('invalidResponse');
    }
    const count = Math.min(data.byteLength, this.limit - this.received);
    const bytes = new Uint8Array(data, 0, count);
    for (let offset = 0; offset < count; offset += CHUNK_BYTES) {
      const end = Math.min(count, offset + CHUNK_BYTES);
      const decoded = this.decoder.decodeToString(bytes.subarray(offset, end), { stream: true });
      this.received += end - offset;
      if (this.mode === 'scan') {
        const window = this.tail + decoded;
        const match = this.pattern?.exec(window);
        if (match !== null && match !== undefined) {
          this.evidence = window.substring(match.index);
          this.finished = true;
          return true;
        }
        // 只保留跨块标记所需的小窗口，不积累整页 HTML。
        this.tail = window.slice(-256);
      } else {
        this.chunks.push(decoded);
      }
    }
    if (this.received === this.limit && this.mode !== 'json') {
      this.finished = true;
      return true;
    }
    return false;
  }

  text(): string {
    if (this.mode === 'scan') { return this.evidence; }
    const end = this.decoder.decodeToString(EMPTY_BYTES);
    if (end !== '') { this.chunks.push(end); }
    return this.chunks.join('');
  }
}
