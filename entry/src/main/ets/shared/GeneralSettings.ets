import { fileIo as fs } from '@kit.CoreFileKit';

export const GENERAL_SETTINGS_FILE = 'general-settings.json';
export const GENERAL_LEVELS: string[] = ['debug', 'info', 'warning', 'error', 'silent'];
export const GENERAL_TIMEOUTS: number[] = [500, 1000, 2000, 5000, 8000];

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
  hosts: Record<string, string[]> | null;
  delayTimeout: number;
  closeConnections?: boolean;
  logLevel: string;
  captureLogs: boolean;
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

function validHost(input: string): boolean {
  return input !== '' && validText(input, 512) && !new RegExp('[\\s/:?#@]').test(input);
}

export function checkedGeneralSettings(input: GeneralSettings): GeneralSettings {
  const invalid = 'general_settings_invalid';
  if (!validText(input.revision, 96) || input.revision === '' ||
    !validText(input.userAgent, 512) || !validText(input.controllerSecret, 512) ||
    input.controllerSecret.includes(' ') || !GENERAL_LEVELS.includes(input.logLevel) ||
    !GENERAL_TIMEOUTS.includes(input.delayTimeout) || typeof input.captureLogs !== 'boolean' ||
    (input.closeConnections !== undefined && typeof input.closeConnections !== 'boolean')) {
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
  return input;
}

export async function generalUserAgent(filesDir: string): Promise<string | undefined> {
  if (filesDir === '') { return undefined; }
  try {
    const saved = JSON.parse(await fs.readText(`${filesDir}/${GENERAL_SETTINGS_FILE}`)) as GeneralSettings;
    return validText(saved.userAgent, 512) && saved.userAgent !== '' ? saved.userAgent : undefined;
  } catch (_error) {
    return undefined;
  }
}
