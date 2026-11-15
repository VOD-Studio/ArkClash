import { ServiceProbeSession, ServiceRuleResult } from './ServiceRuleTypes';
import { serviceBodyContains, serviceFirstMatch, serviceGet, serviceResult, serviceStatusFromCode } from './ServiceRuleCommon';
import { normalizeServiceRegion } from './ServiceRegion';
import { checkChatGpt, checkClaude, checkGemini } from './ServiceAiRules';
import { checkDisneyPlus, checkNetflix } from './ServiceMediaRules';

// 13 项服务协议移植自 FlClash be847366/core/service_rules.go、service_check.go。
const YOUTUBE_REGION_PATTERNS: RegExp[] = [
  new RegExp('id=["\']country-code["\'][^>]*>\\s*([A-Za-z]{2,3})\\s*<', 'i'),
  new RegExp('"GL"\\s*:\\s*"([A-Za-z]{2})"'),
  new RegExp('"countryCode"\\s*:\\s*"([A-Za-z]{2})"'),
  new RegExp('"country_code"\\s*:\\s*"([A-Za-z]{2})"')
];
const TIKTOK_REGION: string = '"webapp\\.app-context"\\s*:\\s*\\{[^{}]*?"region"\\s*:\\s*"([^"]*)"';
// 扫描只返回命中片段，故三种正文拒绝信号也须进入扫描表达式。字符类兼容 JS 与 Go RE2。
const TIKTOK_SCAN: string = TIKTOK_REGION +
  '|[Aa][Cc][Cc][Ee][Ss][Ss] [Dd][Ee][Nn][Ii][Ee][Dd]' +
  '|[Nn][Oo][Tt] [Aa][Vv][Aa][Ii][Ll][Aa][Bb][Ll][Ee] [Ii][Nn] [Yy][Oo][Uu][Rr] [Rr][Ee][Gg][Ii][Oo][Nn]' +
  '|[Tt][Ii][Kk][Tt][Oo][Kk] [Ii][Ss] [Nn][Oo][Tt] [Aa][Vv][Aa][Ii][Ll][Aa][Bb][Ll][Ee]';
const BILIBILI_MAINLAND: string = 'https://api.bilibili.com/pgc/player/web/playurl?' +
  'avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi';
const BILIBILI_HMT: string = 'https://api.bilibili.com/pgc/player/web/playurl?' +
  'avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi';

async function checkReachable(session: ServiceProbeSession, url: string,
  legacy: boolean = false): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, url, 'none');
  const item = serviceResult(reply);
  if (reply.failure === '' && !legacy) { item.availability = serviceStatusFromCode(reply.status); }
  return item;
}

async function checkYouTube(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://www.youtube.com/premium?hl=en', 'html');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  for (const pattern of YOUTUBE_REGION_PATTERNS) {
    const code = serviceFirstMatch(pattern, reply.body);
    if (code !== '') { item.region = normalizeServiceRegion(code); break; }
  }
  if (serviceBodyContains(reply.body, ['youtube premium is not available in your country',
    'premium is not available in your country', 'premium is not available in your region'])) {
    item.availability = 'unsupported-region';
  } else if (reply.status >= 200 && reply.status < 300 &&
    serviceBodyContains(reply.body, ['youtube premium', 'ad-free', '"browseid":"spunlimited"'])) {
    item.availability = 'available';
  } else { item.availability = serviceStatusFromCode(reply.status); }
  return item;
}

function spotifyRegion(url: string, body: string): string {
  const parsed = new RegExp('^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*(/[^?#]*)?').exec(url);
  let path = parsed === null ? url.split('?')[0].split('#')[0] : parsed[1] ?? '';
  try { path = decodeURIComponent(path); } catch (e) { path = ''; }
  const first = path.replace(new RegExp('^/+|/+$', 'g'), '').split('/')[0];
  if (first !== '' && first !== 'api') { return first.split('-')[0]; }
  return serviceFirstMatch(new RegExp('"countryCode"\\s*:\\s*"([^"]+)"'), body);
}

async function checkSpotify(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session,
    'https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  item.region = normalizeServiceRegion(spotifyRegion(reply.url, reply.body));
  if (reply.status === 403 || reply.status === 451) { item.availability = 'unsupported-region'; }
  else if (reply.status < 200 || reply.status >= 300) { item.availability = serviceStatusFromCode(reply.status); }
  else if (serviceBodyContains(reply.body, ['not available in your country'])) { item.availability = 'unsupported-region'; }
  else { item.availability = 'available'; }
  return item;
}

async function checkTikTok(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://www.tiktok.com/', 'scan', TIKTOK_SCAN);
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  item.region = normalizeServiceRegion(serviceFirstMatch(new RegExp(TIKTOK_REGION), reply.body));
  if (reply.status === 403 || reply.status === 451) { item.availability = 'unsupported-region'; }
  else if (reply.status < 200 || reply.status >= 300) { item.availability = 'failed'; }
  else if (serviceBodyContains(reply.body, ['access denied', 'not available in your region', 'tiktok is not available'])) {
    item.availability = 'unsupported-region';
  } else { item.availability = 'available'; }
  return item;
}

async function bilibiliEpisode(session: ServiceProbeSession, url: string): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, url);
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  const code = serviceFirstMatch(new RegExp('^\\s*\\{\\s*"code"\\s*:\\s*(-?\\d+)'), reply.body);
  item.availability = code === '0' ? 'available' : code === '-10403' ? 'unsupported-region' : 'failed';
  return item;
}

async function checkBilibili(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const item = await bilibiliEpisode(session, BILIBILI_MAINLAND);
  if (item.availability === 'available') { item.region = 'CN'; return item; }
  if (item.availability === 'unsupported-region') { return bilibiliEpisode(session, BILIBILI_HMT); }
  return item;
}

async function checkDiscord(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://discord.com/api/v9/auth/location-metadata');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  item.availability = serviceStatusFromCode(reply.status);
  if (item.availability === 'available') {
    item.region = normalizeServiceRegion(serviceFirstMatch(new RegExp('"country_code"\\s*:\\s*"([^"]+)"'), reply.body));
  }
  return item;
}

async function checkPrimeVideo(session: ServiceProbeSession): Promise<ServiceRuleResult> {
  const reply = await serviceGet(session, 'https://www.primevideo.com', 'scan',
    'isServiceRestricted|"currentTerritory":"[^"]+"');
  const item = serviceResult(reply);
  if (reply.failure !== '') { return item; }
  if (reply.body.includes('isServiceRestricted')) { item.availability = 'unsupported-region'; return item; }
  const code = serviceFirstMatch(new RegExp('"currentTerritory":"([^"]+)"'), reply.body);
  if (code === '') { item.availability = 'failed'; return item; }
  item.region = normalizeServiceRegion(code);
  item.availability = 'available';
  return item;
}

export async function checkService(id: string, fallbackUrl: string,
  session: ServiceProbeSession): Promise<ServiceRuleResult> {
  switch (id) {
    case 'google': return checkReachable(session, 'https://www.google.com/generate_204');
    case 'github': return checkReachable(session, 'https://github.com/');
    case 'youtube': return checkYouTube(session);
    case 'chatgpt': return checkChatGpt(session);
    case 'claude': return checkClaude(session);
    case 'gemini': return checkGemini(session);
    case 'netflix': return checkNetflix(session);
    case 'disney-plus': return checkDisneyPlus(session);
    case 'prime-video': return checkPrimeVideo(session);
    case 'spotify': return checkSpotify(session);
    case 'tiktok': return checkTikTok(session);
    case 'discord': return checkDiscord(session);
    case 'bilibili': return checkBilibili(session);
    default: return checkReachable(session, fallbackUrl, true);
  }
}
