import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';
import { DirectProbeRequest } from './DirectProbe';
import { ProbeRequestOptions, ProbeResponse, RoutedProbeError, RoutedProbeFailure } from './ProbeProtocol';

export interface RoutedProbeResult extends ProbeResponse {
  bootId: string;
  revision: number;
}

interface RoutedProbeWire {
  status?: number;
  body?: string;
  bootId?: string;
  revision?: number;
  url?: string;
  location?: string;
  delay?: number;
}

interface ProbeWireRequest extends ProbeRequestOptions {
  timeout: number;
}

interface ProbeWaiter {
  owner: RoutedProbeRequest;
  resolve: () => void;
  reject: (error: RoutedProbeError) => void;
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
  private direct?: DirectProbeRequest;

  cancel(): void {
    this.cancelled = true;
    this.direct?.cancel();
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

  async run(filesDir: string, options: ProbeRequestOptions, timeoutMs: number,
    routed: boolean): Promise<RoutedProbeResult> {
    if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
    let request: http.HttpRequest | undefined = undefined;
    try {
      if (!routed) {
        const direct = new DirectProbeRequest();
        this.direct = direct;
        const response = await direct.run(options, timeoutMs);
        if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
        return { status: response.status, body: response.body, url: response.url, location: response.location,
          delay: response.delay, bootId: '', revision: 0 };
      }
      await this.acquire();
      if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
      const runtime = await readRuntime(filesDir);
      if (runtime === undefined || runtime.secret === '') { throw new RoutedProbeError('controller'); }
      if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
      const command: ProbeWireRequest = {
        url: options.url, method: options.method, bodyMode: options.bodyMode, headers: options.headers,
        body: options.body, noRedirect: options.noRedirect, scanPattern: options.scanPattern, timeout: timeoutMs
      };
      const header: Record<string, string> = {
        'Authorization': `Bearer ${runtime.secret}`, 'Accept': 'application/json', 'Content-Type': 'application/json'
      };
      request = http.createHttp();
      this.request = request;
      const response = await request.request(`http://${CONTROLLER_ADDRESS}/arkclash/probe`, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(command),
        usingProxy: false,
        connectTimeout: 3000,
        readTimeout: timeoutMs + 1500,
        expectDataType: http.HttpDataType.STRING,
        maxLimit: 4 * 1024 * 1024,
        // 控制面不跟随重定向，避免 Authorization 被带到外部地址。
        maxRedirects: 0
      });
      if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
      if (response.responseCode !== 200) {
        throw new RoutedProbeError(routedProbeFailure(response.responseCode), response.responseCode);
      }
      let wire: RoutedProbeWire;
      try { wire = JSON.parse(response.result as string) as RoutedProbeWire; }
      catch (e) { throw new RoutedProbeError('invalidResponse'); }
      if (wire === null || typeof wire.status !== 'number' || !Number.isInteger(wire.status) ||
        wire.status < 100 || wire.status > 599 || typeof wire.body !== 'string' ||
        typeof wire.url !== 'string' || typeof wire.location !== 'string' ||
        typeof wire.delay !== 'number' || !Number.isFinite(wire.delay) || wire.delay < 0 ||
        typeof wire.bootId !== 'string' || wire.bootId === '' || typeof wire.revision !== 'number' ||
        !Number.isInteger(wire.revision) || wire.revision < 0) {
        throw new RoutedProbeError('invalidResponse');
      }
      return { status: wire.status, body: wire.body, url: wire.url, location: wire.location, delay: wire.delay,
        bootId: wire.bootId, revision: wire.revision };
    } catch (e) {
      if (e instanceof RoutedProbeError) { throw e; }
      const reason: RoutedProbeFailure = this.cancelled ? 'cancelled' :
        (e as BusinessError).code === 2300028 ? 'timeout' : 'transport';
      throw new RoutedProbeError(reason);
    } finally {
      this.direct = undefined;
      if (request !== undefined && this.request === request) {
        this.request = undefined;
        request.destroy();
      }
      this.release();
    }
  }
}
