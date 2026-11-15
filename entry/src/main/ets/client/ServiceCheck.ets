import { RoutedProbeError, RoutedProbeFailure, RoutedProbeRequest } from './RoutedProbe';

const TIMEOUT_MS = 5000;
// 给出口查询保留一个执行槽，服务批次与出口合计不超过核心的四槽预算。
const CONCURRENCY = 3;

export type ServiceAvailability = 'unknown' | 'available' | 'restricted' | 'unavailable' | 'disallowed-isp' |
  'blocked' | 'unsupported-region' | 'originals-only' | 'coming-soon' | 'timeout' | 'failed';
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
  if (httpCode === 401 || httpCode === 403 || httpCode === 429 || httpCode === 451) {
    return 'restricted';
  }
  return 'unreachable';
}

/** HTTP 连通性与服务解锁是不同事实；没有服务专用判据时 availability 必须为 unknown。 */
export class ServiceCheckTask {
  private cancelled: boolean = false;
  private requests: Set<RoutedProbeRequest> = new Set<RoutedProbeRequest>();

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
    const results: ServiceResult[] = [];
    let next = 0;
    let bootId = '';
    let revision = -1;
    const worker = async (): Promise<void> => {
      while (!this.cancelled && next < targets.length) {
        const target = targets[next++];
        const result = await this.probe(filesDir, target, route, routed);
        if (routed && result.failure === '') {
          if (bootId !== '' && (bootId !== result.bootId || revision !== result.revision)) {
            throw new RoutedProbeError('routeChanged');
          }
          bootId = result.bootId;
          revision = result.revision;
        }
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

  private async probe(filesDir: string, target: ServiceTarget, route: string, routed: boolean): Promise<ServiceResult> {
    const request = new RoutedProbeRequest();
    this.requests.add(request);
    const begin = Date.now();
    try {
      const response = await request.run(filesDir, target.url, 'HEAD', TIMEOUT_MS, routed);
      return {
        id: target.id,
        delay: Date.now() - begin,
        httpCode: response.status,
        reachability: serviceReachability(response.status),
        availability: 'unknown',
        checkedAt: Date.now(),
        route: route,
        routed: routed,
        bootId: response.bootId,
        revision: response.revision,
        failure: '',
        controlStatus: 0
      };
    } catch (e) {
      if (e instanceof RoutedProbeError && (e.reason === 'routeChanged' || e.reason === 'cancelled')) {
        throw e;
      }
      const reason: RoutedProbeFailure = e instanceof RoutedProbeError ? e.reason : 'transport';
      return {
        id: target.id,
        delay: -1,
        httpCode: 0,
        reachability: reason === 'capacity' ? 'notChecked' : reason === 'timeout' ? 'timeout' : 'failed',
        availability: 'unknown',
        checkedAt: Date.now(),
        route: route,
        routed: routed,
        bootId: '',
        revision: 0,
        failure: reason,
        controlStatus: e instanceof RoutedProbeError ? e.controlStatus : 0
      };
    } finally {
      this.requests.delete(request);
    }
  }
}
