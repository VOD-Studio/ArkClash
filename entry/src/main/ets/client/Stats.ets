// 首页统计卡用的两路推送：活动连接（/connections）和内核内存（/memory）。只在首页可见时订阅。
import { ControllerSocket } from './ControllerSocket';

// /connections 每次推送完整的连接列表，连接多时消息较大，比流量推送放慢一些。
const CONNECTIONS_INTERVAL_MS = 2000;
// 不经过代理节点的出站。
const LOCAL_OUTBOUNDS: string[] = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'];

interface ConnectionInfo {
  chains: string[]; // 实际出站在第一个
}

interface ConnectionsMessage {
  connections: ConnectionInfo[] | null;
}

interface MemoryMessage {
  inuse: number;
}

/** 当前活动连接数，以及其中走代理和直连的各多少。 */
@ObservedV2
export class ConnectionStats {
  @Trace active: number = 0;
  @Trace proxied: number = 0;
  @Trace direct: number = 0;
  @Trace received: boolean = false; // 订阅后收到过数据
  private socket: ControllerSocket = new ControllerSocket(`/connections?interval=${CONNECTIONS_INTERVAL_MS}`,
    (text: string) => this.update(text));

  start(filesDir: string): void {
    this.socket.start(filesDir);
  }

  stop(): void {
    this.socket.stop();
    this.received = false;
  }

  private update(text: string): void {
    const connections = (JSON.parse(text) as ConnectionsMessage).connections ?? [];
    let direct = 0;
    for (const c of connections) {
      const outbound = c.chains.length > 0 ? c.chains[0] : '';
      if (LOCAL_OUTBOUNDS.includes(outbound)) {
        direct++;
      }
    }
    this.active = connections.length;
    this.direct = direct;
    this.proxied = connections.length - direct;
    this.received = true;
  }
}

/** 内核（Go 运行时）当前占用的内存，字节。 */
@ObservedV2
export class MemoryStats {
  @Trace coreBytes: number = 0;
  @Trace received: boolean = false;
  private socket: ControllerSocket = new ControllerSocket('/memory', (text: string) => this.update(text));

  start(filesDir: string): void {
    this.socket.start(filesDir);
  }

  stop(): void {
    this.socket.stop();
    this.received = false;
  }

  private update(text: string): void {
    this.coreBytes = (JSON.parse(text) as MemoryMessage).inuse;
    this.received = true;
  }
}

export const connectionStats: ConnectionStats = new ConnectionStats();
export const memoryStats: MemoryStats = new MemoryStats();
