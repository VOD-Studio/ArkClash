import { ControllerSocket } from './ControllerSocket';

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
  private socket: ControllerSocket = new ControllerSocket('/traffic', (text: string) => this.update(text));

  /** 订阅推送；已经订阅时不做任何事。页面不可见时调用 stop。 */
  start(filesDir: string): void {
    if (this.socket.active) {
      return;
    }
    this.upHistory = [];
    this.downHistory = [];
    this.socket.start(filesDir);
  }

  stop(): void {
    this.socket.stop();
  }

  private update(text: string): void {
    const message = JSON.parse(text) as TrafficMessage;
    this.up = message.up;
    this.down = message.down;
    this.upTotal = message.upTotal;
    this.downTotal = message.downTotal;
    this.upHistory = [...this.upHistory, message.up].slice(-HISTORY_SIZE);
    this.downHistory = [...this.downHistory, message.down].slice(-HISTORY_SIZE);
  }
}

export const traffic: Traffic = new Traffic();
