import { RoutedProbeRequest } from './RoutedProbe';
import { ProbeRequestOptions, RoutedProbeError, RoutedProbeFailure } from './ProbeProtocol';
import { checkService } from './ServiceRules';
import { ServiceAvailability, ServiceProbeReply, ServiceProbeSession } from './ServiceRuleTypes';

const TIMEOUT_MS = 10000;
const SWEEP_TIMEOUT_MS = 6 * TIMEOUT_MS;
// 给出口查询保留一个执行槽，服务批次与出口合计不超过核心的四槽预算。
const CONCURRENCY = 3;

export type ServiceReachability = 'reachable' | 'restricted' | 'unreachable' | 'timeout' | 'failed' | 'notChecked';

export interface ServiceTarget {
  id: string;
  url: string;
}

export interface ServiceResult {
  id: string;
  delay: number;
  httpCode: number;
  reachability: ServiceReachability;
  availability: ServiceAvailability;
  region: string;
  checkedAt: number;
  route: string;
  routed: boolean;
  bootId: string;
  revision: number;
  failure: RoutedProbeFailure | '';
  controlStatus: number;
}

export function serviceReachability(httpCode: number): ServiceReachability {
  if (httpCode >= 200 && httpCode < 400) {
    return 'reachable';
  }
  if (httpCode === 401 || httpCode === 403 || httpCode === 405 || httpCode === 429 || httpCode === 451) {
    return 'restricted';
  }
  return 'unreachable';
}

/** HTTP 连通性与服务解锁是不同事实；没有服务专用判据时 availability 必须为 unknown。 */
export class ServiceCheckTask implements ServiceProbeSession {
  private cancelled: boolean = false;
  private requests: Set<RoutedProbeRequest> = new Set<RoutedProbeRequest>();
  private filesDir: string = '';
  private routed: boolean = false;
  private deadline: number = 0;
  private bootId: string = '';
  private revision: number = 0;

  cancel(): void {
    this.cancelled = true;
    for (const request of this.requests) {
      request.cancel();
    }
    this.requests.clear();
  }

  async run(filesDir: string, targets: ServiceTarget[], route: string, routed: boolean): Promise<ServiceResult[]> {
    if (this.cancelled) {
      throw new RoutedProbeError('cancelled');
    }
    this.filesDir = filesDir;
    this.routed = routed;
    this.deadline = Date.now() + SWEEP_TIMEOUT_MS;
    this.bootId = '';
    this.revision = 0;
    const results: ServiceResult[] = [];
    let next = 0;
    const worker = async (): Promise<void> => {
      while (!this.cancelled && next < targets.length) {
        const target = targets[next++];
        const result = await this.probe(target, route);
        if (!this.cancelled) {
          results.push(result);
        }
      }
    };
    const workers: Promise<void>[] = [];
    for (let index = 0; index < Math.min(CONCURRENCY, targets.length); index++) {
      workers.push(worker());
    }
    try {
      await Promise.all(workers);
    } catch (e) {
      this.cancel();
      if (e instanceof RoutedProbeError) {
        throw e;
      }
      throw new RoutedProbeError('transport');
    }
    if (this.cancelled) {
      throw new RoutedProbeError('cancelled');
    }
    return results;
  }

  async send(options: ProbeRequestOptions): Promise<ServiceProbeReply> {
    if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
    const request = new RoutedProbeRequest();
    this.requests.add(request);
    try {
      const remaining = this.deadline - Date.now();
      if (remaining <= 0) { throw new RoutedProbeError('timeout'); }
      const response = await request.run(this.filesDir, options, Math.min(TIMEOUT_MS, remaining), this.routed);
      if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
      if (this.routed) {
        if (this.bootId !== '' && (this.bootId !== response.bootId || this.revision !== response.revision)) {
          throw new RoutedProbeError('routeChanged');
        }
        this.bootId = response.bootId;
        this.revision = response.revision;
      }
      return { status: response.status, body: response.body, url: response.url, location: response.location,
        delay: response.delay, failure: '' };
    } catch (e) {
      if (!(e instanceof RoutedProbeError) || (e.reason !== 'timeout' && e.reason !== 'transport')) { throw e as Error; }
      return { status: 0, body: '', url: options.url, location: '', delay: 0,
        failure: e.reason === 'timeout' ? 'timeout' : 'failed' };
    } finally {
      this.requests.delete(request);
    }
  }

  private async probe(target: ServiceTarget, route: string): Promise<ServiceResult> {
    try {
      let result = await checkService(target.id, target.url, this);
      if (result.availability === 'timeout' && !this.cancelled && this.deadline - Date.now() >= TIMEOUT_MS) {
        result = await checkService(target.id, target.url, this);
      }
      const availability = result.availability;
      const reachability = ruleReachability(availability, result.httpCode);
      return {
        id: target.id,
        delay: result.delay,
        httpCode: result.httpCode,
        reachability: reachability,
        availability: availability,
        region: result.region,
        checkedAt: Date.now(),
        route: route,
        routed: this.routed,
        bootId: this.bootId,
        revision: this.revision,
        failure: availability === 'timeout' ? 'timeout' :
          availability === 'failed' ? result.httpCode > 0 ? 'invalidResponse' : 'transport' : '',
        controlStatus: 0
      };
    } catch (e) {
      if (e instanceof RoutedProbeError && (e.reason === 'routeChanged' || e.reason === 'cancelled')) { throw e; }
      const reason: RoutedProbeFailure = e instanceof RoutedProbeError ? e.reason : 'transport';
      return {
        id: target.id,
        delay: -1,
        httpCode: 0,
        reachability: reason === 'capacity' ? 'notChecked' : reason === 'timeout' ? 'timeout' : 'failed',
        availability: 'unknown',
        region: '',
        checkedAt: Date.now(),
        route: route,
        routed: this.routed,
        bootId: '',
        revision: 0,
        failure: reason,
        controlStatus: e instanceof RoutedProbeError ? e.controlStatus : 0
      };
    }
  }
}

function ruleReachability(availability: ServiceAvailability, httpCode: number): ServiceReachability {
  switch (availability) {
    case 'available': return 'reachable';
    case 'restricted':
    case 'disallowed-isp':
    case 'blocked':
    case 'unsupported-region':
    case 'originals-only':
    case 'coming-soon': return 'restricted';
    case 'unavailable': return 'unreachable';
    case 'timeout': return 'timeout';
    case 'failed': return 'failed';
    default: return serviceReachability(httpCode);
  }
}
