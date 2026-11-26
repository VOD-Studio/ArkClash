import { ControllerSocket } from './ControllerSocket';

export const HISTORY_SIZE = 30;
const SAMPLE_MS = 1000;
const STALE_MS = 3500;

interface TrafficMessage {
  up: number;
  down: number;
  upTotal?: number;
  downTotal?: number;
}

export interface TrafficSample {
  timestamp: number;
  up: number;
  down: number;
  available: boolean;
}

export function appendTrafficSample(history: TrafficSample[], sample: TrafficSample): TrafficSample[] {
  const bucket = Math.floor(sample.timestamp / SAMPLE_MS) * SAMPLE_MS;
  const points = history.filter((point: TrafficSample): boolean => point.timestamp > bucket - HISTORY_SIZE * SAMPLE_MS &&
    point.timestamp < bucket);
  const previous = points.length > 0 ? points[points.length - 1].timestamp : bucket - SAMPLE_MS;
  for (let gap = Math.max(previous + SAMPLE_MS, bucket - (HISTORY_SIZE - 1) * SAMPLE_MS); gap < bucket;
    gap += SAMPLE_MS) {
    points.push({ timestamp: gap, up: 0, down: 0, available: false });
  }
  points.push({ timestamp: bucket, up: sample.up, down: sample.down, available: sample.available });
  return points.slice(-HISTORY_SIZE);
}

@ObservedV2
export class Traffic {
  @Trace up: number = 0;
  @Trace down: number = 0;
  @Trace upTotal: number = 0;
  @Trace downTotal: number = 0;
  @Trace samples: TrafficSample[] = [];
  @Trace stale: boolean = true;
  @Trace sampledAt: number = 0;
  @Trace error: boolean = false;
  private consumers: Set<string> = new Set<string>();
  private pending?: TrafficMessage;
  private receivedAt: number = 0;
  private startedAt: number = 0;
  private immediatePublish: boolean = false;
  private renderTimer: number = -1;
  private generation: number = 0;
  private socket?: ControllerSocket;

  start(filesDir: string, consumer: string = 'shell'): void {
    this.consumers.add(consumer);
    if (this.renderTimer !== -1) {
      return;
    }
    // 已有历史采样时保留上次速率，避免回前台重连瞬间闪成“—”；超时未收到推送再转过期。
    if (this.sampledAt === 0 || this.error) {
      this.stale = true;
    }
    this.startedAt = Date.now();
    this.immediatePublish = true;
    const generation = ++this.generation;
    this.socket = new ControllerSocket('/traffic', (text: string): void => {
      if (generation === this.generation) {
        this.receive(text);
      }
    });
    this.socket.start(filesDir);
    this.renderTimer = setInterval((): void => this.publish(), SAMPLE_MS);
  }

  stop(consumer: string = 'shell'): void {
    this.consumers.delete(consumer);
    if (this.consumers.size > 0) {
      return;
    }
    this.generation++;
    this.socket?.stop();
    this.socket = undefined;
    if (this.renderTimer !== -1) {
      clearInterval(this.renderTimer);
      this.renderTimer = -1;
    }
    this.pending = undefined;
    this.immediatePublish = false;
  }

  reset(): void {
    this.consumers.clear();
    this.stop();
    this.pending = undefined;
    this.receivedAt = 0;
    this.startedAt = 0;
    this.immediatePublish = false;
    this.sampledAt = 0;
    this.up = 0;
    this.down = 0;
    this.upTotal = 0;
    this.downTotal = 0;
    this.samples = [];
    this.stale = true;
    this.error = false;
  }

  get consumerCount(): number {
    return this.consumers.size;
  }

  private receive(text: string): void {
    if (this.consumers.size === 0) {
      return;
    }
    try {
      const message = JSON.parse(text) as TrafficMessage;
      if (!Number.isFinite(message.up) || !Number.isFinite(message.down) || message.up < 0 || message.down < 0) {
        throw new Error('invalid traffic sample');
      }
      this.pending = message;
      this.receivedAt = Date.now();
      if (this.immediatePublish || this.stale) {
        this.publish();
      }
    } catch (e) {
      this.pending = undefined;
      this.error = true;
      this.stale = true;
    }
  }

  private publish(): void {
    const timestamp = Date.now();
    const message = this.pending;
    this.pending = undefined;
    if (message === undefined) {
      const anchor = Math.max(this.receivedAt, this.startedAt);
      if (anchor > 0 && timestamp - anchor > STALE_MS) {
        this.stale = true;
      }
      return;
    }
    this.immediatePublish = false;
    this.up = message.up;
    this.down = message.down;
    // 累计必须来自核心；缺少累计字段时不在界面进程积分，避免隐藏期间凭空补流量。
    if (message.upTotal !== undefined && Number.isFinite(message.upTotal) && message.upTotal >= 0) {
      this.upTotal = message.upTotal;
    }
    if (message.downTotal !== undefined && Number.isFinite(message.downTotal) && message.downTotal >= 0) {
      this.downTotal = message.downTotal;
    }
    this.samples = appendTrafficSample(this.samples, {
      timestamp: this.receivedAt, up: message.up, down: message.down, available: true
    });
    this.sampledAt = this.receivedAt;
    this.stale = false;
    this.error = false;
  }
}

export const traffic: Traffic = new Traffic();
