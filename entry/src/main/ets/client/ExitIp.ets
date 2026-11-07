// 查询出口公网地址。UI 进程按 UID 排除在 VPN 之外（ADR-0004）：直接请求拿到的是本机直连的地址，
// 要看代理出口就得经内核的 HTTP 代理端口发出。
import { http } from '@kit.NetworkKit';
import { getProxyPort } from './Controller';

// 都返回 ip、country、country_code 和运营商；第一个失败时换下一个。
const LOOKUP_URLS: string[] = ['https://ipwho.is/', 'https://api.ip.sb/geoip'];
const TIMEOUT_MS = 8000;

interface IpConnection {
  org?: string;
  isp?: string;
}

interface LookupResponse {
  ip: string;
  country?: string;
  country_code?: string;
  connection?: IpConnection; // ipwho.is
  organization?: string; // api.ip.sb
  asn_organization?: string; // api.ip.sb
}

export interface ExitIp {
  ip: string;
  country: string;
  countryCode: string; // ISO 3166-1 alpha-2，可能为空
  org: string; // 出口所属的运营商或机构，可能为空
}

// port 为 0 时直连。
async function lookup(url: string, port: number): Promise<ExitIp> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      usingProxy: port > 0 ? { host: '127.0.0.1', port: port, exclusionList: [] } : false,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200) {
      throw new Error(`HTTP ${response.responseCode}`);
    }
    const body = JSON.parse(response.result as string) as LookupResponse;
    const org = body.connection?.org ?? body.connection?.isp ?? body.asn_organization ?? body.organization ?? '';
    return { ip: body.ip, country: body.country ?? '', countryCode: body.country_code ?? '', org: org };
  } finally {
    request.destroy();
  }
}

/**
 * viaProxy 为 true 时查代理出口，否则查本机直连的出口。
 * 经代理查询而配置里没开代理端口，或者所有查询都失败时返回 undefined。
 */
export async function lookupExitIp(filesDir: string, viaProxy: boolean): Promise<ExitIp | undefined> {
  const port = viaProxy ? await getProxyPort(filesDir) : 0;
  if (viaProxy && port <= 0) {
    return undefined;
  }
  for (const url of LOOKUP_URLS) {
    try {
      return await lookup(url, port);
    } catch (e) {
      // 换下一个
    }
  }
  return undefined;
}

/** 国家代码转旗帜 emoji；无效代码返回空串。 */
export function flagOf(countryCode: string): string {
  if (!/^[A-Za-z]{2}$/.test(countryCode)) {
    return '';
  }
  const base = 0x1F1E6;
  const upper = countryCode.toUpperCase();
  return String.fromCodePoint(base + upper.charCodeAt(0) - 65, base + upper.charCodeAt(1) - 65);
}
