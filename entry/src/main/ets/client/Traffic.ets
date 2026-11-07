import { webSocket } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';

// 内核重启或刚启动时 WebSocket 可能连不上，重试有上限，避免内核不在时空转耗电。
const RETRY_DELAY_MS = 2000;
const MAX_RETRIES = 5;
// 速率曲线保留的样本数；内核每秒推一次，即最近一分钟。
export const HISTORY_SIZE = 60;

interface TrafficMessage {
  up: number;
  down: number;
  upTotal: number;
  downTotal: number;
}

/** 内核 /traffic 推送的速率（字节/秒）和本次连接的累计流量（字节）。内核每秒推一次。 */
@ObservedV2
export class Traffic {
  @Trace up: number = 0;
  @Trace down: number = 0;
  @Trace upTotal: number = 0;
  @Trace downTotal: number = 0;
  // 最近 HISTORY_SIZE 秒的速率，旧的在前。退订后保留，重新订阅时清空。
  @Trace upHistory: number[] = [];
  @Trace downHistory: number[] = [];
  private socket?: webSocket.WebSocket;
  private filesDir: string = '';
  private retries: number = 0;
  private retryTimer: number = -1;

  /** 订阅推送；已经订阅时不做任何事。页面不可见时调用 stop。 */
  start(filesDir: string): void {
    if (this.socket !== undefined || this.retryTimer !== -1) {
      return;
    }
    this.filesDir = filesDir;
    this.retries = 0;
    this.upHistory = [];
    this.downHistory = [];
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
      const message = JSON.parse(data) as TrafficMessage;
      this.up = message.up;
      this.down = message.down;
      this.upTotal = message.upTotal;
      this.downTotal = message.downTotal;
      this.upHistory = [...this.upHistory, message.up].slice(-HISTORY_SIZE);
      this.downHistory = [...this.downHistory, message.down].slice(-HISTORY_SIZE);
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
    socket.connect(`ws://${CONTROLLER_ADDRESS}/traffic`, { header: header }).catch(retry);
  }
}

export const traffic: Traffic = new Traffic();
