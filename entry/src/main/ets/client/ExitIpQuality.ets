export type ExitIpType = 'residential' | 'mobile' | 'business' | 'hosting';
export type ExitIpQualityLevel = 'good' | 'normal' | 'risky';

export interface ExitIpQuality {
  ip: string;
  type: ExitIpType;
  level: ExitIpQualityLevel;
  source: string;
  checkedAt: number;
  isProxy: boolean;
  isVpn: boolean;
  isTor: boolean;
  isAbuser: boolean;
}

interface QualityOrganization {
  type?: string;
}

interface QualityPrivacy {
  is_hosting?: boolean;
  is_proxy?: boolean;
  is_vpn?: boolean;
  is_tor?: boolean;
  is_abuser?: boolean;
}

interface QualityResponse {
  ip?: string;
  type?: string;
  company?: QualityOrganization;
  asn?: QualityOrganization;
  privacy?: QualityPrivacy;
  is_datacenter?: boolean;
  is_mobile?: boolean;
  is_proxy?: boolean;
  is_vpn?: boolean;
  is_tor?: boolean;
  is_abuser?: boolean;
}

export const EXIT_IP_QUALITY_SOURCES: string[] = ['ident.me', 'iplocate.io', 'ipapi.is'];

export function exitIpQualityUrl(source: string, address: string): string {
  switch (source) {
    case 'ident.me': return 'https://ident.me/json';
    case 'ipapi.is': return `https://api.ipapi.is/?q=${encodeURIComponent(address)}`;
    default: return `https://iplocate.io/api/lookup/${encodeURIComponent(address)}`;
  }
}

function declaredType(value: string | undefined): ExitIpType | undefined {
  switch (value) {
    case 'isp': return 'residential';
    case 'business':
    case 'education':
    case 'government':
    case 'banking': return 'business';
    case 'hosting': return 'hosting';
    default: return undefined;
  }
}

function canonicalAddress(address: string): string {
  if (!address.includes(':')) {
    return address;
  }
  if (!new RegExp('^[0-9a-fA-F:]+$').test(address)) {
    return '';
  }
  const halves = address.toLowerCase().split('::');
  if (halves.length > 2 || halves.some((half: string): boolean => half.startsWith(':') || half.endsWith(':'))) {
    return '';
  }
  const left = halves[0] === '' ? [] : halves[0].split(':');
  const right = halves.length < 2 || halves[1] === '' ? [] : halves[1].split(':');
  const count = left.length + right.length;
  if ((halves.length === 1 && count !== 8) || (halves.length === 2 && count >= 8) ||
    left.some((part: string): boolean => part.length > 4) || right.some((part: string): boolean => part.length > 4)) {
    return '';
  }
  const parts: string[] = left.map((part: string): string => parseInt(part, 16).toString(16));
  for (let index = count; index < 8; index++) { parts.push('0'); }
  for (const part of right) { parts.push(parseInt(part, 16).toString(16)); }
  return parts.join(':');
}

export function parseExitIpQuality(text: string, address: string, source: string): ExitIpQuality | undefined {
  let body: QualityResponse;
  try {
    body = JSON.parse(text) as QualityResponse;
  } catch (e) {
    return undefined;
  }
  if (typeof body?.ip !== 'string' || canonicalAddress(body.ip) !== canonicalAddress(address)) {
    return undefined;
  }
  const privacy = body.privacy;
  const declared = declaredType(body.type) ?? declaredType(body.company?.type) ?? declaredType(body.asn?.type);
  const type: ExitIpType | undefined = body.is_datacenter === true || privacy?.is_hosting === true || declared === 'hosting' ?
    'hosting' : body.is_mobile === true ? 'mobile' : declared;
  if (type === undefined) {
    return undefined;
  }
  const isTor = body.is_tor === true || privacy?.is_tor === true;
  const isAbuser = body.is_abuser === true || privacy?.is_abuser === true;
  return {
    ip: address, type: type, level: isTor || isAbuser ? 'risky' : type === 'hosting' ? 'normal' : 'good',
    source: source, checkedAt: Date.now(),
    isProxy: body.is_proxy === true || privacy?.is_proxy === true,
    isVpn: body.is_vpn === true || privacy?.is_vpn === true,
    isTor: isTor, isAbuser: isAbuser
  };
}
