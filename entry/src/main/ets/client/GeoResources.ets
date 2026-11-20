import { http } from '@kit.NetworkKit';
import { call } from './Controller';
import { GEO_RESOURCE_IDS, GeoResourceId, GeoSnapshot } from '../shared/GeoResources';

interface GeoApplyBody {
  expectedBootId: string;
  revision: string;
}

interface GeoUpdateBody {
  expectedBootId: string;
  ids: GeoResourceId[];
}

interface GeoStreamMessage {
  type: string;
  snapshot: GeoSnapshot;
}

export function parseGeoEvent(text: string): GeoSnapshot {
  const event = JSON.parse(text) as GeoStreamMessage;
  if (event?.type !== 'geo') { throw new Error('geo_invalid_data'); }
  return checkedGeoSnapshot(event.snapshot);
}

// 只允许固定错误码进入界面，controller 和网络原始错误可能含凭据。
export function geoResourceError(error: Object): string {
  const message = (error as Error).message;
  const codes: string[] = ['geo_invalid_settings', 'geo_invalid_url', 'geo_invalid_data', 'geo_metadata_invalid',
    'geo_io', 'geo_timeout', 'geo_download_failed', 'geo_canceled', 'geo_stale_boot', 'geo_settings_conflict'];
  return codes.includes(message) || new RegExp('^geo_http_[1-5][0-9]{2}$').test(message) ?
    message : 'geo_download_failed';
}

export function parseGeoSnapshot(text: string): GeoSnapshot {
  return checkedGeoSnapshot(JSON.parse(text) as GeoSnapshot);
}

function checkedGeoSnapshot(snapshot: GeoSnapshot): GeoSnapshot {
  if (snapshot === null || snapshot === undefined || typeof snapshot !== 'object' || typeof snapshot.bootId !== 'string' ||
    snapshot.bootId.length === 0 || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0 ||
    typeof snapshot.settingsRevision !== 'string' || !Array.isArray(snapshot.items) || snapshot.items.length !== 4) {
    throw new Error('geo_invalid_data');
  }
  const seen: GeoResourceId[] = [];
  for (const item of snapshot.items) {
    if (item === null || typeof item !== 'object' || !GEO_RESOURCE_IDS.includes(item.id) || seen.includes(item.id) ||
      typeof item.fileName !== 'string' || typeof item.exists !== 'boolean' ||
      !Number.isFinite(item.size) || item.size < 0 || !Number.isFinite(item.modifiedAt) || item.modifiedAt < 0 ||
      !['idle', 'queued', 'updating'].includes(item.phase) || typeof item.operationId !== 'string' ||
      !['none', 'updated', 'unchanged', 'failed', 'canceled'].includes(item.outcome) || typeof item.error !== 'string' ||
      !Number.isSafeInteger(item.receivedBytes ?? 0) || (item.receivedBytes ?? 0) < 0 ||
      !Number.isSafeInteger(item.totalBytes ?? 0) || (item.totalBytes ?? 0) < 0) {
      throw new Error('geo_invalid_data');
    }
    seen.push(item.id);
    if (item.error !== '') { item.error = geoResourceError(new Error(item.error)); }
  }
  return snapshot;
}

export async function getGeoSnapshot(filesDir: string): Promise<GeoSnapshot> {
  try { return parseGeoSnapshot(await call(filesDir, http.RequestMethod.GET, '/arkclash/geo')); }
  catch (error) { throw new Error(geoResourceError(error as Object)); }
}

export async function applyGeoSettings(filesDir: string, bootId: string, revision: string): Promise<GeoSnapshot> {
  const body: GeoApplyBody = { expectedBootId: bootId, revision: revision };
  try {
    return parseGeoSnapshot(await call(filesDir, http.RequestMethod.POST, '/arkclash/geo/settings', JSON.stringify(body)));
  } catch (error) { throw new Error(geoResourceError(error as Object)); }
}

export async function updateGeoResources(filesDir: string, bootId: string,
  ids: GeoResourceId[]): Promise<GeoSnapshot> {
  const body: GeoUpdateBody = { expectedBootId: bootId, ids: ids };
  try {
    return parseGeoSnapshot(await call(filesDir, http.RequestMethod.POST, '/arkclash/geo/update', JSON.stringify(body)));
  } catch (error) { throw new Error(geoResourceError(error as Object)); }
}
