import { webSocket } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';

// 内核重启或刚启动时 WebSocket 可能连不上，重试有上限，避免内核不在时空转耗电。
const RETRY_DELAY_MS = 2000;
const MAX_RETRIES = 5;

/**
 * controller 的一路 WebSocket 推送（/traffic、/connections、/memory 等）。
 * 页面可见时 start，不可见时 stop；收到的每条文本消息交给 onMessage。
 */
export class ControllerSocket {
  private path: string;
  private onMessage: (text: string) => void;
  private socket?: webSocket.WebSocket;
  private filesDir: string = '';
  private retries: number = 0;
  private retryTimer: number = -1;

  /** path 含查询参数，比如 '/connections?interval=2000'。 */
  constructor(path: string, onMessage: (text: string) => void) {
    this.path = path;
    this.onMessage = onMessage;
  }

  get active(): boolean {
    return this.socket !== undefined || this.retryTimer !== -1;
  }

  /** 已经在订阅时不做任何事。 */
  start(filesDir: string): void {
    if (this.active) {
      return;
    }
    this.filesDir = filesDir;
    this.retries = 0;
    this.open();
  }

  stop(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const socket = this.socket;
    this.socket = undefined;
    socket?.off('message');
    socket?.off('close');
    socket?.off('error');
    socket?.close().catch(() => {});
  }

  private open(): void {
    const runtime = readRuntime(this.filesDir);
    if (runtime === undefined) {
      return;
    }
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('message', (err, data) => {
      if (err || typeof data !== 'string') {
        return;
      }
      this.retries = 0;
      this.onMessage(data);
    });
    const retry = () => {
      if (this.socket !== socket) {
        return;
      }
      this.stop();
      if (this.retries >= MAX_RETRIES) {
        return;
      }
      this.retries++;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.open();
      }, RETRY_DELAY_MS);
    };
    socket.on('close', retry);
    socket.on('error', retry);
    const header: Record<string, string> = { 'Authorization': `Bearer ${runtime.secret}` };
    socket.connect(`ws://${CONTROLLER_ADDRESS}${this.path}`, { header: header }).catch(retry);
  }
}
