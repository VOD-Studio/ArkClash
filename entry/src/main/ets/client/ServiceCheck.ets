// 服务状态：经内核的 HTTP 代理端口逐个请求服务，记从发出到收到响应的耗时。
// UI 进程不走 VPN（ADR-0004），只能经代理端口，见 docs/architecture.md。
import { http } from '@kit.NetworkKit';
import { getProxyPort } from './Controller';

const TIMEOUT_MS = 5000;
// 同时在途的请求数上限；服务多的时候不一次全发出去。
const CONCURRENCY = 6;

export interface ServiceTarget {
  id: string;
  url: string; // 用 HEAD 请求，收到任何 HTTP 响应都算可达
}

/** delay 单位 ms；-1 = 不可达或超时。 */
export interface ServiceResult {
  id: string;
  delay: number;
}

async function probe(target: ServiceTarget, port: number): Promise<ServiceResult> {
  const request = http.createHttp();
  const begin = Date.now();
  try {
    await request.request(target.url, {
      method: http.RequestMethod.HEAD,
      usingProxy: { host: '127.0.0.1', port: port, exclusionList: [] },
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS
    });
    return { id: target.id, delay: Date.now() - begin };
  } catch (e) {
    return { id: target.id, delay: -1 };
  } finally {
    request.destroy();
  }
}

/** 检测给定的服务；配置里没开代理端口时全部记为不可达。结果顺序不保证。 */
export async function checkServices(filesDir: string, targets: ServiceTarget[]): Promise<ServiceResult[]> {
  const port = await getProxyPort(filesDir);
  if (port <= 0) {
    return targets.map((t: ServiceTarget): ServiceResult => ({ id: t.id, delay: -1 }));
  }
  const results: ServiceResult[] = [];
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < targets.length) {
      const target = targets[next++];
      results.push(await probe(target, port));
    }
  };
  const workers: Promise<void>[] = [];
  for (let i = 0; i < Math.min(CONCURRENCY, targets.length); i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}
