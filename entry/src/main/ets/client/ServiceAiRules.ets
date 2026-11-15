import { ServiceProbeSession, ServiceRuleResult } from './ServiceRuleTypes';
import { serviceBodyContains, serviceGet, serviceResult, serviceTraceValue } from './ServiceRuleCommon';
import { normalizeServiceRegion } from './ServiceRegion';

// AI 服务判据移植自 FlClash be847366/core/service_rules.go。
const CLAUDE_BLOCKED_REGIONS: string[] = ['AF', 'BY', 'CN', 'CU', 'HK', 'IR', 'KP', 'MO', 'RU', 'SY'];
const GEMINI_BLOCKED_REGIONS: string[] = ['CHN', 'RUS', 'BLR', 'CUB', 'IRN', 'PRK', 'SYR', 'HKG', 'MAC'];
const GEMINI_MARKER: string = ',2,1,200,"';

export async function checkClaude(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://claude.ai/cdn-cgi/trace');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  item.region = normalizeServiceRegion(serviceTraceValue(reply.body, 'loc'));
  if (item.region === '') { item.availability = 'failed'; return item; }
  item.availability = CLAUDE_BLOCKED_REGIONS.includes(item.region) ? 'unsupported-region' : 'available';
  return item;
}

export async function checkGemini(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://gemini.google.com', 'scan', GEMINI_MARKER + '[A-Z]{3}');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  const index = reply.body.indexOf(GEMINI_MARKER);
  if (index < 0) { item.availability = 'failed'; return item; }
  const code = reply.body.substring(index + GEMINI_MARKER.length, index + GEMINI_MARKER.length + 3);
  if (!new RegExp('^[A-Z]{3}$').test(code)) { item.availability = 'failed'; return item; }
  item.region = normalizeServiceRegion(code);
  item.availability = GEMINI_BLOCKED_REGIONS.includes(code) ? 'unsupported-region' : 'available';
  return item;
}

export async function checkChatGpt(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const ios = await serviceGet(session, 'https://ios.chat.openai.com/');
  const item = serviceResult(ios);
  if (ios.failure === '') {
    if (serviceBodyContains(ios.body, ['you may be connected to a disallowed isp'])) {
      item.availability = 'disallowed-isp';
    } else if (serviceBodyContains(ios.body, ['sorry, you have been blocked'])) {
      item.availability = 'blocked';
    } else if (serviceBodyContains(ios.body, ['request is not allowed. please try again later.'])) {
      // 该端点在可用地区拒绝普通 API 客户端；这条特定拒绝才是上游成功信号。
      item.availability = 'available';
    } else {
      item.availability = 'failed';
    }
  }
  const trace = await serviceGet(session, 'https://chat.openai.com/cdn-cgi/trace');
  if (trace.failure === '') { item.region = normalizeServiceRegion(serviceTraceValue(trace.body, 'loc')); }
  const web = await serviceGet(session, 'https://api.openai.com/compliance/cookie_requirements');
  if (web.failure === '' && serviceBodyContains(web.body, ['unsupported_country'])) {
    item.availability = 'unsupported-region';
  }
  return item;
}
