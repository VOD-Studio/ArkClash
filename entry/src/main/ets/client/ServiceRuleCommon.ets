import { ProbeBodyMode, ProbeRequestOptions } from './ProbeProtocol';
import { ServiceAvailability, ServiceProbeReply, ServiceProbeSession, ServiceRuleResult } from './ServiceRuleTypes';

// 检测协议移植自 FlClash be847366/core/service_check.go。
export const SERVICE_BROWSER_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

export async function serviceGet(session: ServiceProbeSession, url: string, bodyMode: ProbeBodyMode = 'small',
  scanPattern: string = '', noRedirect: boolean = false): Promise<ServiceProbeReply> {
  const options: ProbeRequestOptions = {
    url: url, method: 'GET', bodyMode: bodyMode,
    headers: { 'User-Agent': SERVICE_BROWSER_UA }, noRedirect: noRedirect
  };
  if (scanPattern !== '') { options.scanPattern = scanPattern; }
  return session.send(options);
}

export function serviceResult(reply: ServiceProbeReply): ServiceRuleResult {
  return {
    availability: reply.failure === '' ? 'unknown' : reply.failure,
    region: '', delay: reply.failure === '' ? reply.delay : 0, httpCode: reply.status
  };
}

export function serviceStatusFromCode(code: number): ServiceAvailability {
  if (code >= 200 && code < 300) { return 'available'; }
  if (code === 401 || code === 403 || code === 429 || code === 451) { return 'restricted'; }
  return 'unavailable';
}

export function serviceFirstMatch(pattern: RegExp, body: string): string {
  const match = pattern.exec(body);
  return match === null || match.length < 2 ? '' : match[1];
}

export function serviceBodyContains(body: string, needles: string[]): boolean {
  const lower = body.toLowerCase();
  return needles.some((needle: string): boolean => lower.includes(needle));
}

export function serviceTraceValue(body: string, key: string): string {
  const prefix = key + '=';
  for (const line of body.split('\n')) {
    if (line.startsWith(prefix)) { return line.substring(prefix.length).trim(); }
  }
  return '';
}

// 单独解码字段字符串：small 模式允许前缀截断，不能要求整份 JSON 可解析。
export function serviceJsonString(body: string, key: string): string {
  const captured = serviceFirstMatch(new RegExp('"' + key + '"\\s*:\\s*"((?:[^"\\\\]|\\\\.)+)"'), body);
  if (captured === '') { return ''; }
  try {
    const decoded = JSON.parse('"' + captured + '"') as string;
    return typeof decoded === 'string' ? decoded : '';
  } catch (e) {
    return '';
  }
}

// Go url.QueryEscape 的空格及保留字符规则与 encodeURIComponent 不同。
export function serviceFormEscape(text: string): string {
  return encodeURIComponent(text).replace(new RegExp('[!\'()*]', 'g'), (character: string): string => {
    return '%' + character.charCodeAt(0).toString(16).toUpperCase();
  }).replace(new RegExp('%20', 'g'), '+');
}
