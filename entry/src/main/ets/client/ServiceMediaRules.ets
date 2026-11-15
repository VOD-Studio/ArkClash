import { ProbeRequestOptions } from './ProbeProtocol';
import { ServiceProbeReply, ServiceProbeSession, ServiceRuleResult } from './ServiceRuleTypes';
import { SERVICE_BROWSER_UA, serviceFirstMatch, serviceFormEscape, serviceGet, serviceJsonString, serviceResult,
  serviceStatusFromCode } from './ServiceRuleCommon';
import { normalizeServiceRegion } from './ServiceRegion';

// 流媒体握手与回退判据移植自 FlClash be847366/core/service_rules.go。
// 两个常量均为上游网页公开客户端标识，不包含用户帐号凭据。
const DISNEY_AUTH: string = "Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84";
const NETFLIX_CDN_URL: string = "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5";

interface ServiceNetflixLocation { country?: string; }
interface ServiceNetflixTarget { location?: ServiceNetflixLocation; }
interface ServiceNetflixPayload { targets?: ServiceNetflixTarget[]; }
interface ServiceDisneyTokenInput { refreshToken: string; }
interface ServiceDisneyVariables { input: ServiceDisneyTokenInput; }
interface ServiceDisneyQuery { query: string; variables: ServiceDisneyVariables; }

function netflixCountry(body: string): string | undefined {
  let payload: ServiceNetflixPayload;
  try { payload = JSON.parse(body) as ServiceNetflixPayload; } catch (e) { return undefined; }
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload) ||
    !Array.isArray(payload.targets) || payload.targets.length === 0) { return undefined; }
  // 与 Go 的结构化解码一致：任一已知字段类型错误都使 CDN 结果进入标题回退。
  for (const target of payload.targets) {
    if (target === null) { continue; }
    if (typeof target !== 'object' || Array.isArray(target)) { return undefined; }
    const location = target.location;
    if (location === undefined || location === null) { continue; }
    if (typeof location !== 'object' || Array.isArray(location)) { return undefined; }
    const country = location.country;
    if (country !== undefined && country !== null && typeof country !== 'string') { return undefined; }
  }
  const country = payload.targets[0]?.location?.country;
  return typeof country === 'string' ? country : '';
}

async function netflixFromCdn(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, NETFLIX_CDN_URL);
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  if (reply.status === 403) { item.availability = 'blocked'; return item; }
  const country = netflixCountry(reply.body);
  if (country === undefined) { item.availability = 'failed'; return item; }
  item.region = normalizeServiceRegion(country);
  item.availability = 'available';
  return item;
}

async function netflixRegion(session: ServiceProbeSession): Promise<string> {
  const reply = await serviceGet(session, 'https://www.netflix.com/title/80018499', 'none', '', true);
  if (reply.failure !== '') { return ''; }
  const segments = reply.location.split('/');
  return segments.length < 4 ? '' : normalizeServiceRegion(segments[3].split('-')[0]);
}

export async function checkNetflix(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const cdn = await netflixFromCdn(session);
  if (cdn.availability === 'available' || cdn.availability === 'blocked') { return cdn; }
  const first = await serviceGet(session, 'https://www.netflix.com/title/81280792', 'none');
  const item = serviceResult(first);
  if (first.failure !== '') { return item; }
  const second = await serviceGet(session, 'https://www.netflix.com/title/70143836', 'none');
  if (second.failure !== '') { return serviceResult(second); }
  if (first.status === 404 && second.status === 404) { item.availability = 'originals-only'; }
  else if (first.status === 403 || second.status === 403) { item.availability = 'unsupported-region'; }
  else if (first.status === 200 || first.status === 301 || second.status === 200 || second.status === 301) {
    item.availability = 'available';
    item.region = await netflixRegion(session);
  } else { item.availability = serviceStatusFromCode(first.status); }
  return item;
}

async function disneyPost(session: ServiceProbeSession, url: string, contentType: string,
  body: string): Promise<ServiceProbeReply> {
  const options: ProbeRequestOptions = {
    url: url, method: 'POST', bodyMode: 'small',
    headers: { 'User-Agent': SERVICE_BROWSER_UA, 'Authorization': DISNEY_AUTH, 'Content-Type': contentType },
    body: body
  };
  return session.send(options);
}

export async function checkDisneyPlus(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const device = await disneyPost(session, 'https://disney.api.edge.bamgrid.com/devices',
    'application/json; charset=UTF-8',
    '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}');
  const item = serviceResult(device);
  if (device.failure !== '') { return item; }
  if (device.status === 403) { item.availability = 'blocked'; return item; }
  const assertion = serviceJsonString(device.body, 'assertion');
  if (assertion === '') { item.availability = 'failed'; return item; }
  const form = 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' +
    '&latitude=0&longitude=0&platform=browser&subject_token=' + serviceFormEscape(assertion) +
    '&subject_token_type=urn:bamtech:params:oauth:token-type:device';
  const token = await disneyPost(session, 'https://disney.api.edge.bamgrid.com/token',
    'application/x-www-form-urlencoded', form);
  if (token.failure !== '') { return serviceResult(token); }
  if (token.body.includes('forbidden-location') || token.body.includes('403 ERROR')) {
    item.availability = 'blocked'; return item;
  }
  const refresh = serviceJsonString(token.body, 'refresh_token');
  if (refresh === '') { item.availability = 'failed'; return item; }
  const input: ServiceDisneyTokenInput = { refreshToken: refresh };
  const variables: ServiceDisneyVariables = { input: input };
  const query: ServiceDisneyQuery = {
    query: 'mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) ' +
      '{ activeSession { sessionId } } }', variables: variables
  };
  const graph = await disneyPost(session, 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql',
    'application/json', JSON.stringify(query));
  if (graph.failure !== '' || graph.body === '' || graph.status >= 400) {
    item.availability = 'failed'; return item;
  }
  item.region = normalizeServiceRegion(serviceFirstMatch(new RegExp('"countryCode"\\s*:\\s*"([^"]+)"'), graph.body));
  if (item.region === '') { item.availability = 'unavailable'; return item; }
  const supported = serviceFirstMatch(new RegExp('"inSupportedLocation"\\s*:\\s*(false|true)'), graph.body);
  item.availability = supported === 'true' ? 'available' : supported === 'false' ? 'coming-soon' : 'failed';
  return item;
}
