import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';

export type RoutedProbeMethod = 'GET' | 'HEAD';
export type RoutedProbeFailure = 'cancelled' | 'capacity' | 'routeChanged' | 'timeout' | 'transport' | 'controller' |
  'invalidResponse';

export interface RoutedProbeResult {
  status: number;
  body: string;
  bootId: string;
  revision: number;
}

interface RoutedProbeWire {
  status?: number;
  body?: string;
  bootId?: string;
  revision?: number;
}

interface ProbeWaiter {
  owner: RoutedProbeRequest;
  resolve: () => void;
  reject: (error: RoutedProbeError) => void;
}

export class RoutedProbeError extends Error {
  reason: RoutedProbeFailure;
  controlStatus: number;

  constructor(reason: RoutedProbeFailure, controlStatus: number = 0) {
    super('probe request failed');
    this.reason = reason;
    this.controlStatus = controlStatus;
  }
}

function routedProbeFailure(status: number): RoutedProbeFailure {
  switch (status) {
    case 409: return 'routeChanged';
    case 429: return 'capacity';
    case 504: return 'timeout';
    case 503: return 'transport';
    default: return 'controller';
  }
}

/** 运行时由核心规则拨号；停止时 SDK 直连。controller 凭据只发送给本机控制面。 */
export class RoutedProbeRequest {
  private static active: number = 0;
  private static waiting: ProbeWaiter[] = [];
  private acquired: boolean = false;
  private cancelled: boolean = false;
  private request?: http.HttpRequest;

  cancel(): void {
    this.cancelled = true;
    const index = RoutedProbeRequest.waiting.findIndex((waiter: ProbeWaiter): boolean => waiter.owner === this);
    if (index >= 0) {
      RoutedProbeRequest.waiting.splice(index, 1)[0].reject(new RoutedProbeError('cancelled'));
    }
    const request = this.request;
    this.request = undefined;
    request?.destroy();
  }

  private acquire(): Promise<void> {
    // 与内核的四个执行名额一致；旧请求真正结束后，新出口才接手名额。
    if (RoutedProbeRequest.active < 4) {
      RoutedProbeRequest.active++;
      this.acquired = true;
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject): void => {
      RoutedProbeRequest.waiting.push({ owner: this, resolve: resolve, reject: reject });
    });
  }

  private release(): void {
    if (!this.acquired) { return; }
    this.acquired = false;
    const next = RoutedProbeRequest.waiting.shift();
    if (next === undefined) {
      RoutedProbeRequest.active--;
    } else {
      next.owner.acquired = true;
      next.resolve();
    }
  }

  async run(filesDir: string, target: string, method: RoutedProbeMethod, timeoutMs: number,
    routed: boolean): Promise<RoutedProbeResult> {
    if (this.cancelled) {
      throw new RoutedProbeError('cancelled');
    }
    let request: http.HttpRequest | undefined = undefined;
    try {
      let address = target;
      const header: Record<string, string> = {};
      if (routed) {
        await this.acquire();
        if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
        const runtime = await readRuntime(filesDir);
        if (runtime === undefined || runtime.secret === '') {
          throw new RoutedProbeError('controller');
        }
        address = `http://${CONTROLLER_ADDRESS}/arkclash/probe?url=${encodeURIComponent(target)}` +
          `&method=${method}&timeout=${timeoutMs}`;
        header['Authorization'] = `Bearer ${runtime.secret}`;
        header['Accept'] = 'application/json';
      }
      if (this.cancelled) {
        throw new RoutedProbeError('cancelled');
      }
      request = http.createHttp();
      this.request = request;
      const response = await request.request(address, {
        method: routed || method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.HEAD,
        header: header,
        usingProxy: false,
        connectTimeout: routed ? 3000 : timeoutMs,
        readTimeout: routed ? timeoutMs + 1500 : timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        maxLimit: routed ? 512 * 1024 : 64 * 1024,
        // 控制面不跟随重定向，避免 Authorization 被带到外部地址。
        maxRedirects: routed ? 0 : 30
      });
      if (this.cancelled) {
        throw new RoutedProbeError('cancelled');
      }
      if (!routed) {
        if (method === 'GET' && typeof response.result !== 'string') {
          throw new RoutedProbeError('invalidResponse');
        }
        return {
          status: response.responseCode,
          body: method === 'HEAD' ? '' : response.result as string,
          bootId: '',
          revision: 0
        };
      }
      if (response.responseCode !== 200) {
        throw new RoutedProbeError(routedProbeFailure(response.responseCode), response.responseCode);
      }
      let wire: RoutedProbeWire;
      try {
        wire = JSON.parse(response.result as string) as RoutedProbeWire;
      } catch (e) {
        throw new RoutedProbeError('invalidResponse');
      }
      if (wire === null || typeof wire.status !== 'number' || !Number.isInteger(wire.status) ||
        wire.status < 100 || wire.status > 599 || typeof wire.body !== 'string' ||
        typeof wire.bootId !== 'string' || wire.bootId === '' || typeof wire.revision !== 'number' ||
        !Number.isInteger(wire.revision) || wire.revision < 0) {
        throw new RoutedProbeError('invalidResponse');
      }
      return { status: wire.status, body: wire.body, bootId: wire.bootId, revision: wire.revision };
    } catch (e) {
      if (e instanceof RoutedProbeError) {
        throw e;
      }
      const reason: RoutedProbeFailure = this.cancelled ? 'cancelled' :
        (e as BusinessError).code === 2300028 ? 'timeout' : 'transport';
      throw new RoutedProbeError(reason);
    } finally {
      if (request !== undefined && this.request === request) {
        this.request = undefined;
        request.destroy();
      }
      this.release();
    }
  }
}
