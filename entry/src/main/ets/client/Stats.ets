import { hidebug } from '@kit.PerformanceAnalysisKit';
import { ControllerSocket } from './ControllerSocket';

const LOCAL_OUTBOUNDS: string[] = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'];

interface StatsConnectionInfo {
  chains?: string[];
}

interface StatsConnectionsMessage {
  connections: StatsConnectionInfo[] | null;
}

interface StatsMemoryMessage {
  inuse: number;
}

@ObservedV2
export class ConnectionStats {
  @Trace active: number = 0;
  @Trace proxied: number = 0;
  @Trace direct: number = 0;
  @Trace received: boolean = false;
  @Trace sampledAt: number = 0;
  @Trace failed: boolean = false;
  private consumers: Set<string> = new Set<string>();
  private socket: ControllerSocket = new ControllerSocket('/connections?interval=1000',
    (text: string): void => this.update(text));

  start(filesDir: string, consumer: string = 'dashboard'): void {
    this.consumers.add(consumer);
    this.socket.start(filesDir);
  }

  stop(consumer: string = 'dashboard'): void {
    this.consumers.delete(consumer);
    if (this.consumers.size === 0) {
      this.socket.stop();
    }
  }

  reset(): void {
    this.active = 0;
    this.proxied = 0;
    this.direct = 0;
    this.sampledAt = 0;
    this.received = false;
    this.failed = false;
  }

  private update(text: string): void {
    if (this.consumers.size === 0) {
      return;
    }
    try {
      const connections = (JSON.parse(text) as StatsConnectionsMessage).connections ?? [];
      let direct = 0;
      let proxied = 0;
      for (const item of connections) {
        const chains = item.chains ?? [];
        if (chains.length === 0) {
          continue;
        }
        if (LOCAL_OUTBOUNDS.includes(chains[0])) {
          direct++;
        } else {
          proxied++;
        }
      }
      this.active = connections.length;
      this.direct = direct;
      this.proxied = proxied;
      this.received = true;
      this.failed = false;
      this.sampledAt = Date.now();
    } catch (e) {
      this.failed = true;
    }
  }
}

/** /memory.inuse 是 VPN 进程 RSS，不能与界面进程 PSS + SwapPss 相加。 */
@ObservedV2
export class MemoryStats {
  @Trace coreBytes: number = 0;
  @Trace received: boolean = false;
  @Trace sampledAt: number = 0;
  @Trace failed: boolean = false;
  private consumers: Set<string> = new Set<string>();
  private socket: ControllerSocket = new ControllerSocket('/memory', (text: string): void => this.update(text));

  start(filesDir: string, consumer: string = 'dashboard'): void {
    this.consumers.add(consumer);
    this.socket.start(filesDir);
  }

  stop(consumer: string = 'dashboard'): void {
    this.consumers.delete(consumer);
    if (this.consumers.size === 0) {
      this.socket.stop();
    }
  }

  reset(): void {
    this.coreBytes = 0;
    this.sampledAt = 0;
    this.received = false;
    this.failed = false;
  }

  private update(text: string): void {
    if (this.consumers.size === 0) {
      return;
    }
    try {
      const bytes = (JSON.parse(text) as StatsMemoryMessage).inuse;
      if (!Number.isFinite(bytes) || bytes < 0) {
        throw new Error('invalid memory sample');
      }
      this.coreBytes = bytes;
      this.received = true;
      this.failed = false;
      this.sampledAt = Date.now();
    } catch (e) {
      this.failed = true;
    }
  }
}

@ObservedV2
export class UiMemoryStats {
  @Trace pssSwapBytes: number = 0;
  @Trace rssBytes: number = 0;
  @Trace sampledAt: number = 0;
  @Trace failed: boolean = false;
  private generation: number = 0;
  private reading: boolean = false;

  stop(): void {
    this.generation++;
  }

  async refresh(): Promise<void> {
    if (this.reading) {
      return;
    }
    const generation = this.generation;
    this.reading = true;
    try {
      const info = await hidebug.getAppNativeMemInfoAsync();
      if (generation !== this.generation) {
        return;
      }
      // API26 NativeMemInfo.pss 已含 SwapPss，不能再次加交换页。
      this.pssSwapBytes = Number(info.pss) * 1024;
      this.rssBytes = Number(info.rss) * 1024;
      this.sampledAt = Date.now();
      this.failed = false;
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      this.reading = false;
    }
  }
}

export const connectionStats: ConnectionStats = new ConnectionStats();
export const memoryStats: MemoryStats = new MemoryStats();
export const uiMemoryStats: UiMemoryStats = new UiMemoryStats();
