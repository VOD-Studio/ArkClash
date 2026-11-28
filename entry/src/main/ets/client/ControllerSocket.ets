import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CONTROLLER_ADDRESS, readRuntime, RuntimeConfig } from '../shared/Runtime';

// 内核重启或刚启动时 WebSocket 可能连不上，重试有上限，避免内核不在时空转耗电。
const RETRY_DELAY_MS = 2000;
const MAX_RETRIES = 5;

export type ControllerSocketState = 'connecting' | 'open' | 'retrying' | 'closed' | 'failed';

/**
 * controller 的一路 WebSocket 推送（/traffic、/connections、/memory 等）。
 * 订阅方决定生命周期；收到的文本消息交给 onMessage。
 */
export class ControllerSocket {
  private path: string;
  private onMessage: (text: string) => void;
  private onState?: (state: ControllerSocketState) => void;
  private retryAcknowledgement?: string;
  private socket?: webSocket.WebSocket;
  private filesDir: string = '';
  private retries: number = 0;
  private retryTimer: number = -1;
  private generation: number = 0;
  private opening: boolean = false;
  private currentState: ControllerSocketState = 'closed';
  failure: string = '';

  /** path 含查询参数，比如 '/connections?interval=2000'。 */
  constructor(path: string, onMessage: (text: string) => void,
    onState?: (state: ControllerSocketState) => void, retryAcknowledgement?: string) {
    this.path = path;
    this.onMessage = onMessage;
    this.onState = onState;
    this.retryAcknowledgement = retryAcknowledgement;
  }

  get active(): boolean {
    return this.opening || this.socket !== undefined || this.retryTimer !== -1;
  }

  get state(): ControllerSocketState { return this.currentState; }

  /** 已经在订阅时不做任何事。 */
  start(filesDir: string): void {
    if (this.active) {
      return;
    }
    this.filesDir = filesDir;
    this.retries = 0;
    this.failure = '';
    this.open();
  }

  stop(): void {
    this.dispose();
    this.failure = '';
    this.notify('closed');
  }

  // 协议损坏不能套用网络重试；显式重试 start 才建立新会话。
  fail(reason: string): void {
    this.dispose();
    this.failure = reason;
    this.notify('failed');
  }

  private notify(state: ControllerSocketState): void {
    if (state === this.currentState) { return; }
    this.currentState = state;
    this.onState?.(state);
  }

  private dispose(): void {
    ++this.generation;
    this.opening = false;
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const socket = this.socket;
    this.socket = undefined;
    socket?.off('message');
    socket?.off('open');
    socket?.off('close');
    socket?.off('error');
    socket?.close().catch((): void => {});
  }

  private retry(socket: webSocket.WebSocket): void {
    if (this.socket !== socket) { return; }
    this.dispose();
    if (this.retries >= MAX_RETRIES) {
      this.notify('failed');
      return;
    }
    this.retries++;
    const generation = this.generation;
    this.notify('retrying');
    if (generation !== this.generation) { return; }
    this.retryTimer = setTimeout((): void => {
      if (generation !== this.generation) { return; }
      this.retryTimer = -1;
      this.open();
    }, RETRY_DELAY_MS);
  }

  private open(): void {
    const generation = ++this.generation;
    this.opening = true;
    this.notify('connecting');
    if (generation !== this.generation) { return; }
    readRuntime(this.filesDir).then((runtime: RuntimeConfig | undefined): void => {
      if (generation !== this.generation) {
        return;
      }
      this.opening = false;
      if (runtime === undefined) {
        this.notify('closed');
        return;
      }
      const socket = webSocket.createWebSocket();
      this.socket = socket;
      socket.on('open', (error: BusinessError): void => {
        if (generation !== this.generation || this.socket !== socket) { return; }
        if (error) { this.retry(socket); }
        else { this.notify('open'); }
      });
      socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
        if (generation !== this.generation || this.socket !== socket || error || typeof data !== 'string') {
          return;
        }
        if (this.retryAcknowledgement === undefined || data === this.retryAcknowledgement) {
          this.retries = 0;
        }
        this.onMessage(data);
      });
      const retry = (): void => { this.retry(socket); };
      socket.on('close', retry);
      socket.on('error', retry);
      const header: Record<string, string> = { 'Authorization': `Bearer ${runtime.secret}` };
      // 系统客户端默认 30s 发 ping、30s 收不到 pong 就断开；mihomo 的 /traffic 等推送端点从不回 pong，
      // 每 60s 断线重连一次，曲线留下断档。回环连接靠 close 事件和推送超时判断存活，关掉心跳。
      // pongTimeout 不能大于 pingInterval，两个一起置 0。
      socket.connect(`ws://${CONTROLLER_ADDRESS}${this.path}`, { header: header, pingInterval: 0, pongTimeout: 0 })
        .then((created: boolean): void => { if (created === false) { retry(); } }).catch(retry);
    }).catch((): void => {
      if (generation === this.generation) {
        this.dispose();
        this.notify('failed');
      }
    });
  }
}
