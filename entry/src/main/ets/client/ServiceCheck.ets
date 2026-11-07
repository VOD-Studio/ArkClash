// 首页「服务状态」：经内核的 HTTP 代理端口逐个请求常用服务，记从发出到收到响应的耗时。
// UI 进程不走 VPN（ADR-0004），只能经代理端口，见 docs/architecture.md。
import { http } from '@kit.NetworkKit';
import { getProxyPort } from './Controller';

const TIMEOUT_MS = 5000;

export interface Service {
  name: string;
  short: string; // 卡片上的字母头像
  url: string; // 用 HEAD 请求，收到任何 HTTP 响应都算可达
}

export const SERVICES: Service[] = [
  { name: 'Google', short: 'G', url: 'https://www.google.com/generate_204' },
  { name: 'GitHub', short: 'GH', url: 'https://github.com/' },
  { name: 'YouTube', short: 'YT', url: 'https://www.youtube.com/generate_204' },
  { name: 'ChatGPT', short: 'AI', url: 'https://chatgpt.com/' }
];

/** delay 单位 ms；-1 = 不可达或超时。 */
export interface ServiceResult {
  name: string;
  delay: number;
}

async function probe(service: Service, port: number): Promise<ServiceResult> {
  const request = http.createHttp();
  const begin = Date.now();
  try {
    await request.request(service.url, {
      method: http.RequestMethod.HEAD,
      usingProxy: { host: '127.0.0.1', port: port, exclusionList: [] },
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS
    });
    return { name: service.name, delay: Date.now() - begin };
  } catch (e) {
    return { name: service.name, delay: -1 };
  } finally {
    request.destroy();
  }
}

/** 并发检测全部服务；配置里没开代理端口时全部记为不可达。 */
export async function checkServices(filesDir: string): Promise<ServiceResult[]> {
  const port = await getProxyPort(filesDir);
  if (port <= 0) {
    return SERVICES.map((s: Service): ServiceResult => ({ name: s.name, delay: -1 }));
  }
  return Promise.all(SERVICES.map((s: Service) => probe(s, port)));
}
