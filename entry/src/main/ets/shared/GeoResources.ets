import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { url } from '@kit.ArkTS';
import { writeTextAsync } from './Files';

export type GeoResourceId = 'mmdb' | 'asn' | 'geoip' | 'geosite';
export type GeoResourcePhase = 'idle' | 'queued' | 'updating';
export type GeoResourceOutcome = 'none' | 'updated' | 'unchanged' | 'failed' | 'canceled';

export interface GeoUrls {
  mmdb: string;
  asn: string;
  geoip: string;
  geosite: string;
}

export interface GeoSettings {
  version: number;
  revision: string;
  autoUpdate: boolean;
  intervalHours: number;
  urls: GeoUrls;
}

export interface GeoResourceStatus {
  id: GeoResourceId;
  fileName: string;
  exists: boolean;
  size: number;
  modifiedAt: number;
  phase: GeoResourcePhase;
  operationId: string;
  outcome: GeoResourceOutcome;
  error: string;
}

export interface GeoSnapshot {
  bootId: string;
  revision: number;
  settingsRevision: string;
  items: GeoResourceStatus[];
}

export interface GeoMetadata {
  version: number;
  managed: boolean;
  lastAttemptAt: number;
}

export const GEO_RESOURCE_IDS: GeoResourceId[] = ['mmdb', 'asn', 'geoip', 'geosite'];
const GEO_URL_BASE = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/';
export const GEO_DEFAULT_URLS: GeoUrls = {
  mmdb: `${GEO_URL_BASE}geoip.metadb`,
  asn: `${GEO_URL_BASE}GeoLite2-ASN.mmdb`,
  geoip: `${GEO_URL_BASE}geoip.dat`,
  geosite: `${GEO_URL_BASE}geosite.dat`
};

let settingsQueue: Promise<void> = Promise.resolve();
let latestSave: Promise<void> = Promise.resolve();

export function defaultGeoSettings(): GeoSettings {
  return { version: 1, revision: 'default', autoUpdate: false, intervalHours: 24,
    urls: { mmdb: GEO_DEFAULT_URLS.mmdb, asn: GEO_DEFAULT_URLS.asn,
      geoip: GEO_DEFAULT_URLS.geoip, geosite: GEO_DEFAULT_URLS.geosite } };
}

export function validateGeoUrl(source: string): boolean {
  if (typeof source !== 'string' || source.length === 0 || source.length > 2048 || source.trim() !== source ||
    !new RegExp('^https?://[^/?#]', 'i').test(source) || source.includes('\\') ||
    new RegExp('^https?://[^/?#]*@', 'i').test(source) ||
    new RegExp('[\\u0000-\\u0020\\u007f]').test(source)) { return false; }
  try {
    const parsed = url.URL.parseURL(source);
    return (parsed.protocol === 'https:' || parsed.protocol === 'http:') && parsed.hostname !== '' &&
      parsed.href.length <= 2048 && parsed.username === '' && parsed.password === '';
  } catch (_error) {
    return false;
  }
}

function checkedSettings(settings: GeoSettings): GeoSettings {
  if (settings === null || typeof settings !== 'object' || settings.version !== 1 ||
    typeof settings.revision !== 'string' || settings.revision.length === 0 ||
    typeof settings.autoUpdate !== 'boolean' || !Number.isInteger(settings.intervalHours) ||
    settings.intervalHours < 1 || settings.intervalHours > 8760 ||
    settings.urls === null || typeof settings.urls !== 'object') {
    throw new Error('geo_invalid_settings');
  }
  if (!validateGeoUrl(settings.urls.mmdb) || !validateGeoUrl(settings.urls.asn) ||
    !validateGeoUrl(settings.urls.geoip) || !validateGeoUrl(settings.urls.geosite)) {
    throw new Error('geo_invalid_url');
  }
  return { version: 1, revision: settings.revision, autoUpdate: settings.autoUpdate,
    intervalHours: settings.intervalHours, urls: { mmdb: settings.urls.mmdb, asn: settings.urls.asn,
      geoip: settings.urls.geoip, geosite: settings.urls.geosite } };
}

export function geoMissingFile(error: Object): boolean {
  const code = (error as BusinessError).code;
  return code === 13900002 || code === 2;
}

export async function readGeoOptionalText(path: string): Promise<string | undefined> {
  try {
    return await fs.readText(path);
  } catch (error) {
    if (geoMissingFile(error as Object)) { return undefined; }
    throw new Error('geo_io');
  }
}

async function readSettingsFile(filesDir: string): Promise<GeoSettings> {
  const text = await readGeoOptionalText(`${filesDir}/geo-settings.json`);
  if (text === undefined) { return defaultGeoSettings(); }
  let parsed: GeoSettings;
  try {
    parsed = JSON.parse(text) as GeoSettings;
  } catch (_error) {
    throw new Error('geo_invalid_settings');
  }
  return checkedSettings(parsed);
}

export async function readGeoSettings(filesDir: string): Promise<GeoSettings> {
  // 提交失败不遮蔽磁盘上的旧值，便于冲突后重新读取；启动屏障仍会传播最后一次失败。
  await settingsQueue;
  return readSettingsFile(filesDir);
}

function enqueueSettings(filesDir: string, settings: GeoSettings, reset: boolean): Promise<GeoSettings> {
  const operation = settingsQueue.then(async (): Promise<GeoSettings> => {
    const saved = checkedSettings(settings);
    if (!reset) {
      const current = await readSettingsFile(filesDir);
      if (current.revision !== saved.revision) { throw new Error('geo_settings_conflict'); }
    }
    saved.revision = `${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
    try {
      await writeTextAsync(`${filesDir}/geo-settings.json`, JSON.stringify(saved));
    } catch (_error) {
      throw new Error('geo_io');
    }
    return saved;
  });
  latestSave = operation.then((): void => {});
  // 队列只负责串行化，不让某次失败阻断用户下一次主动保存或恢复。
  settingsQueue = latestSave.catch((): void => {});
  return operation;
}

export function saveGeoSettings(filesDir: string, settings: GeoSettings): Promise<GeoSettings> {
  // 入队时复制草稿，调用方随后编辑不能改变本次提交。
  let draft: GeoSettings;
  try { draft = checkedSettings(settings); }
  catch (error) {
    return enqueueRejectedSettings(error as Error);
  }
  return enqueueSettings(filesDir, draft, false);
}

function enqueueRejectedSettings(error: Error): Promise<GeoSettings> {
  const rejected = settingsQueue.then((): GeoSettings => { throw error; });
  latestSave = rejected.then((): void => {});
  settingsQueue = latestSave.catch((): void => {});
  return rejected;
}

export function resetGeoSettings(filesDir: string): Promise<GeoSettings> {
  return enqueueSettings(filesDir, defaultGeoSettings(), true);
}

export function flushGeoSettings(): Promise<void> {
  return latestSave;
}

export async function readGeoMetadata(filesDir: string, id: GeoResourceId): Promise<GeoMetadata | undefined> {
  const text = await readGeoOptionalText(`${filesDir}/geo-${id}.json`);
  if (text === undefined) { return undefined; }
  try {
    const parsed = JSON.parse(text) as GeoMetadata;
    if (parsed === null || typeof parsed !== 'object' || parsed.version !== 1 ||
      typeof parsed.managed !== 'boolean' || !Number.isSafeInteger(parsed.lastAttemptAt) || parsed.lastAttemptAt < 0) {
      throw new Error('geo_metadata_invalid');
    }
    return { version: 1, managed: parsed.managed, lastAttemptAt: parsed.lastAttemptAt };
  } catch (_error) {
    throw new Error('geo_metadata_invalid');
  }
}

function defaultGeoFileName(id: GeoResourceId): string {
  switch (id) {
    case 'mmdb': return 'geoip.metadb';
    case 'asn': return 'ASN.mmdb';
    case 'geoip': return 'GeoIP.dat';
    case 'geosite': return 'geosite.dat';
  }
}

function matchesGeoFile(id: GeoResourceId, name: string): boolean {
  const lower = name.toLowerCase();
  switch (id) {
    case 'mmdb': return lower === 'country.mmdb' || lower === 'geoip.db' || lower === 'geoip.metadb';
    case 'asn': return lower === 'asn.mmdb';
    case 'geoip': return lower === 'geoip.dat';
    case 'geosite': return lower === 'geosite.dat';
  }
}

async function readGeoFileInfo(filesDir: string, id: GeoResourceId, names: string[]): Promise<GeoResourceStatus> {
  const result: GeoResourceStatus = { id: id, fileName: defaultGeoFileName(id), exists: false, size: 0,
    modifiedAt: 0, phase: 'idle', operationId: '', outcome: 'none', error: '' };
  for (const name of names) {
    if (!matchesGeoFile(id, name)) { continue; }
    try {
      const stat = await fs.stat(`${filesDir}/${name}`);
      if (!stat.isFile()) { continue; }
      result.fileName = name;
      result.exists = true;
      result.size = stat.size;
      result.modifiedAt = stat.mtime * 1000;
      break;
    } catch (error) {
      if (geoMissingFile(error as Object)) { continue; }
      result.error = 'geo_io';
      return result;
    }
  }
  try { await readGeoMetadata(filesDir, id); }
  catch (error) { result.error = (error as Error).message; }
  return result;
}

export async function readGeoFileInfos(filesDir: string): Promise<GeoResourceStatus[]> {
  let names: string[];
  try { names = await fs.listFile(filesDir); }
  catch (_error) { throw new Error('geo_io'); }
  names.sort();
  const items: GeoResourceStatus[] = [];
  for (const id of GEO_RESOURCE_IDS) {
    items.push(await readGeoFileInfo(filesDir, id, names));
  }
  return items;
}
