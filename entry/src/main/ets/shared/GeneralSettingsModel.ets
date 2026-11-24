export const GENERAL_SETTINGS_FILE = 'general-settings.json';
export const GENERAL_LEVELS: string[] = ['debug', 'info', 'warning', 'error', 'silent'];
export const GENERAL_TIMEOUTS: number[] = [500, 1000, 2000, 5000, 8000];
export const GENERAL_GEODATA_LOADERS: string[] = ['standard', 'memconservative'];
export const DEFAULT_GENERAL_TEST_URL = 'https://www.gstatic.com/generate_204';
export const GENERAL_USER_AGENT_LIMIT = 64;

export type GeneralGeodataLoader = 'standard' | 'memconservative';

export interface GeneralCoreOverrides {
  testUrl?: string;
  unifiedDelay?: boolean;
  tcpConcurrent?: boolean;
  ipv6?: boolean;
  geodataLoader?: GeneralGeodataLoader;
}

export interface GeneralPorts {
  mixed: number;
  http: number;
  socks: number;
  redir: number;
  tproxy: number;
}

export interface GeneralAuthentication {
  enabled: boolean;
  username: string;
  password: string;
}

export interface GeneralSettings {
  revision: string;
  ports?: GeneralPorts;
  authentication?: GeneralAuthentication;
  controllerSecret: string;
  userAgent: string;
  userAgents?: string[];
  appendSystemDns?: boolean;
  hosts: Record<string, string[]> | null;
  delayTimeout: number;
  closeConnections?: boolean;
  logLevel: string;
  captureLogs: boolean;
  coreOverrides?: GeneralCoreOverrides;
}

export function defaultGeneralPorts(): GeneralPorts {
  return { mixed: 7890, http: 0, socks: 0, redir: 0, tproxy: 0 };
}

export function defaultGeneralSettings(): GeneralSettings {
  return { revision: 'default', controllerSecret: '', userAgent: '', hosts: null,
    delayTimeout: 8000, logLevel: 'error', captureLogs: false };
}

function validText(input: string, limit: number): boolean {
  return typeof input === 'string' && input.length <= limit && input.trim() === input &&
    !new RegExp('[\\x00-\\x1f\\x7f-\\x9f]').test(input);
}

export function validGeneralUserAgent(input: string): boolean {
  return validText(input, 512);
}

export function validGeneralTestUrl(input: string): boolean {
  if (!validText(input, 2048) || input === '' || new RegExp('\\s').test(input)) {
    return false;
  }
  const match = new RegExp('^https?://([^/?#]+)(?:[/?#].*)?$').exec(input);
  if (match === null) {
    return false;
  }
  const authority = match[1];
  const atIndex = authority.lastIndexOf('@');
  const hostPort = atIndex >= 0 ? authority.slice(atIndex + 1) : authority;
  if (hostPort === '') {
    return false;
  }
  if (hostPort.startsWith('[')) {
    const end = hostPort.indexOf(']');
    if (end <= 1) {
      return false;
    }
    const rest = hostPort.slice(end + 1);
    return rest === '' || new RegExp('^:[0-9]{1,5}$').test(rest);
  }
  const colon = hostPort.indexOf(':');
  if (colon >= 0) {
    return colon > 0 && new RegExp('^[0-9]{1,5}$').test(hostPort.slice(colon + 1));
  }
  return true;
}

export function generalTestUrl(settings: GeneralSettings): string {
  const candidate = settings.coreOverrides?.testUrl;
  return candidate !== undefined && validGeneralTestUrl(candidate) ? candidate : DEFAULT_GENERAL_TEST_URL;
}

export function compactGeneralCoreOverrides(input: GeneralCoreOverrides | undefined): GeneralCoreOverrides | undefined {
  if (input === undefined) {
    return undefined;
  }
  const next: GeneralCoreOverrides = {};
  let hasEntry = false;
  if (input.testUrl !== undefined) { next.testUrl = input.testUrl; hasEntry = true; }
  if (input.unifiedDelay !== undefined) { next.unifiedDelay = input.unifiedDelay; hasEntry = true; }
  if (input.tcpConcurrent !== undefined) { next.tcpConcurrent = input.tcpConcurrent; hasEntry = true; }
  if (input.ipv6 !== undefined) { next.ipv6 = input.ipv6; hasEntry = true; }
  if (input.geodataLoader !== undefined) { next.geodataLoader = input.geodataLoader; hasEntry = true; }
  return hasEntry ? next : undefined;
}

function validHost(input: string): boolean {
  return input !== '' && validText(input, 512) && !new RegExp('[\\s/:?#@]').test(input);
}

const CORE_OVERRIDE_KEYS: string[] = ['testUrl', 'unifiedDelay', 'tcpConcurrent', 'ipv6', 'geodataLoader'];

export function checkedGeneralSettings(input: GeneralSettings): GeneralSettings {
  const invalid = 'general_settings_invalid';
  if (!validText(input.revision, 96) || input.revision === '' ||
    !validGeneralUserAgent(input.userAgent) || !validText(input.controllerSecret, 512) ||
    input.controllerSecret.includes(' ') || !GENERAL_LEVELS.includes(input.logLevel) ||
    !GENERAL_TIMEOUTS.includes(input.delayTimeout) || typeof input.captureLogs !== 'boolean' ||
    (input.appendSystemDns !== undefined && typeof input.appendSystemDns !== 'boolean') ||
    (input.closeConnections !== undefined && typeof input.closeConnections !== 'boolean')) {
    throw new Error(invalid);
  }
  const agents = input.userAgents;
  if (agents !== undefined && (!Array.isArray(agents) || agents.length > GENERAL_USER_AGENT_LIMIT ||
    !agents.every((agent: string): boolean => agent !== '' && validGeneralUserAgent(agent)) ||
    new Set<string>(agents).size !== agents.length)) {
    throw new Error(invalid);
  }
  const port = input.ports;
  if (port !== undefined) {
    const seen = new Set<number>(input.controllerSecret === '' ? [19090] : [19090, 9090]);
    if (port.mixed === 0) { throw new Error(invalid); }
    for (const item of [port.mixed, port.http, port.socks, port.redir, port.tproxy]) {
      if (item === 0) { continue; }
      if (!Number.isInteger(item) || item < 1024 || item > 49151 || seen.has(item)) { throw new Error(invalid); }
      seen.add(item);
    }
  }
  const auth = input.authentication;
  if (auth !== undefined && (typeof auth.enabled !== 'boolean' || !validText(auth.username, 128) ||
    !validText(auth.password, 512) || auth.username.includes(':') ||
    (auth.enabled && (auth.username === '' || auth.password === '')))) {
    throw new Error(invalid);
  }
  if (input.hosts !== null) {
    if (typeof input.hosts !== 'object' || Array.isArray(input.hosts)) { throw new Error(invalid); }
    const domains = Object.keys(input.hosts);
    if (domains.length > 256) { throw new Error(invalid); }
    for (const domain of domains) {
      const addresses = input.hosts[domain];
      if (!validHost(domain) || !Array.isArray(addresses) || addresses.length === 0 || addresses.length > 32 ||
        !addresses.every((address: string): boolean => validHost(address) ||
          (validText(address, 512) && new RegExp('^[0-9A-Fa-f:.]+$').test(address)))) {
        throw new Error(invalid);
      }
    }
  }
  const overrides = input.coreOverrides;
  if (overrides !== undefined) {
    if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides)) {
      throw new Error(invalid);
    }
    for (const key of Object.keys(overrides)) {
      if (!CORE_OVERRIDE_KEYS.includes(key)) {
        throw new Error(invalid);
      }
    }
    if ((overrides.testUrl !== undefined && !validGeneralTestUrl(overrides.testUrl)) ||
      (overrides.unifiedDelay !== undefined && typeof overrides.unifiedDelay !== 'boolean') ||
      (overrides.tcpConcurrent !== undefined && typeof overrides.tcpConcurrent !== 'boolean') ||
      (overrides.ipv6 !== undefined && typeof overrides.ipv6 !== 'boolean') ||
      (overrides.geodataLoader !== undefined &&
        (typeof overrides.geodataLoader !== 'string' || !GENERAL_GEODATA_LOADERS.includes(overrides.geodataLoader)))) {
      throw new Error(invalid);
    }
  }
  return input;
}
