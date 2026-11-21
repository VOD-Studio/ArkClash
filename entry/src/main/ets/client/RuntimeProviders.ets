import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ensureProfilesDir, newId, profileWorkDir, removeProfileFile } from '../shared/profiles/Store';
import { call } from './Controller';

export type RuntimeProviderKind = 'proxy' | 'rule';
export type RuntimeProviderVehicle = 'http' | 'file' | 'inline';
export type RuntimeProviderPhase = 'idle' | 'updating';
export type RuntimeProviderOutcome = 'none' | 'updated' | 'unchanged' | 'failed';

export interface RuntimeProviderItem {
  kind: RuntimeProviderKind;
  name: string;
  vehicleType: RuntimeProviderVehicle;
  count: number;
  updatedAt: number;
  behavior?: string;
  format?: string;
  updatable: boolean;
  replaceable: boolean;
  phase: RuntimeProviderPhase;
  outcome: RuntimeProviderOutcome;
  error: string;
}

export interface RuntimeProvidersSnapshot {
  bootId: string;
  configRevision: number;
  profile: string;
  revision: number;
  items: RuntimeProviderItem[];
}

interface ProviderUpdateRequest {
  bootId: string;
  configRevision: number;
  kind: RuntimeProviderKind;
  name: string;
}

interface ProviderReplaceRequest {
  bootId: string;
  configRevision: number;
  kind: RuntimeProviderKind;
  name: string;
  candidate: string;
}

interface ProviderStreamMessage {
  type: string;
  snapshot: RuntimeProvidersSnapshot;
}

const PROVIDER_CANDIDATE_LIMIT = 16 * 1024 * 1024;
const KNOWN_PROVIDER_ERRORS: string[] = [
  'provider_unavailable', 'provider_stale_config', 'provider_not_found', 'provider_not_updatable',
  'provider_not_replaceable', 'provider_busy', 'provider_invalid_request', 'provider_invalid_content',
  'provider_timeout', 'provider_update_failed', 'provider_io'
];

export function runtimeProviderKey(kind: RuntimeProviderKind, name: string): string {
  return `${kind}:${name}`;
}

// 仅放行固定错误码到界面，屏蔽上游 URL、路径或网络细节。
export function runtimeProviderError(error: Object): string {
  const message = (error as Error).message;
  return KNOWN_PROVIDER_ERRORS.includes(message) ? message : 'provider_update_failed';
}

function checkedProviderSnapshot(snapshot: RuntimeProvidersSnapshot): RuntimeProvidersSnapshot {
  if (snapshot === null || snapshot === undefined || typeof snapshot !== 'object' ||
    typeof snapshot.bootId !== 'string' || snapshot.bootId.length === 0 ||
    !Number.isSafeInteger(snapshot.configRevision) || snapshot.configRevision < 1 ||
    typeof snapshot.profile !== 'string' ||
    !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0 ||
    !Array.isArray(snapshot.items)) {
    throw new Error('provider_invalid_content');
  }
  const seen = new Set<string>();
  const items: RuntimeProviderItem[] = [];
  for (const raw of snapshot.items) {
    if (raw === null || raw === undefined || typeof raw !== 'object' ||
      (raw.kind !== 'proxy' && raw.kind !== 'rule') ||
      typeof raw.name !== 'string' || raw.name.length === 0 ||
      (raw.vehicleType !== 'http' && raw.vehicleType !== 'file' && raw.vehicleType !== 'inline') ||
      !Number.isSafeInteger(raw.count) || raw.count < 0 ||
      !Number.isFinite(raw.updatedAt) || raw.updatedAt < 0 ||
      typeof raw.updatable !== 'boolean' || typeof raw.replaceable !== 'boolean' ||
      (raw.phase !== 'idle' && raw.phase !== 'updating') ||
      (raw.outcome !== 'none' && raw.outcome !== 'updated' && raw.outcome !== 'unchanged' && raw.outcome !== 'failed') ||
      typeof raw.error !== 'string') {
      throw new Error('provider_invalid_content');
    }
    const key = runtimeProviderKey(raw.kind, raw.name);
    if (seen.has(key)) {
      throw new Error('provider_invalid_content');
    }
    seen.add(key);
    items.push({
      kind: raw.kind,
      name: raw.name,
      vehicleType: raw.vehicleType,
      count: raw.count,
      updatedAt: raw.updatedAt,
      behavior: typeof raw.behavior === 'string' ? raw.behavior : '',
      format: typeof raw.format === 'string' ? raw.format : '',
      updatable: raw.updatable,
      replaceable: raw.replaceable,
      phase: raw.phase,
      outcome: raw.outcome,
      error: raw.error === '' ? '' : runtimeProviderError(new Error(raw.error))
    });
  }
  return {
    bootId: snapshot.bootId,
    configRevision: snapshot.configRevision,
    profile: snapshot.profile,
    revision: snapshot.revision,
    items: items
  };
}

export function parseRuntimeProvidersSnapshot(text: string): RuntimeProvidersSnapshot {
  return checkedProviderSnapshot(JSON.parse(text) as RuntimeProvidersSnapshot);
}

export function parseRuntimeProvidersEvent(text: string): RuntimeProvidersSnapshot {
  const message = JSON.parse(text) as ProviderStreamMessage;
  if (message === null || message === undefined || message.type !== 'providers') {
    throw new Error('provider_invalid_content');
  }
  return checkedProviderSnapshot(message.snapshot);
}

export async function getRuntimeProviders(filesDir: string): Promise<RuntimeProvidersSnapshot> {
  try {
    return parseRuntimeProvidersSnapshot(await call(filesDir, http.RequestMethod.GET, '/arkclash/providers'));
  } catch (error) {
    throw new Error(runtimeProviderError(error as Object));
  }
}

export async function updateRuntimeProvider(filesDir: string, bootId: string, configRevision: number,
  kind: RuntimeProviderKind, name: string): Promise<RuntimeProvidersSnapshot> {
  const body: ProviderUpdateRequest = {
    bootId: bootId,
    configRevision: configRevision,
    kind: kind,
    name: name
  };
  try {
    const response = await call(filesDir, http.RequestMethod.POST, '/arkclash/providers/update',
      JSON.stringify(body), 30000);
    return parseRuntimeProvidersSnapshot(response);
  } catch (error) {
    throw new Error(runtimeProviderError(error as Object));
  }
}

export async function replaceRuntimeProviderFromUri(filesDir: string, bootId: string, configRevision: number,
  kind: RuntimeProviderKind, name: string, uri: string): Promise<RuntimeProvidersSnapshot> {
  let candidatePath = '';
  try {
    await ensureProfilesDir(filesDir);
    candidatePath = `${profileWorkDir(filesDir)}/${newId('prov-')}.candidate`;
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = (await fs.stat(file.fd)).size;
      if (size <= 0 || size > PROVIDER_CANDIDATE_LIMIT) {
        throw new Error('provider_invalid_content');
      }
      await fs.copyFile(file.fd, candidatePath);
    } finally {
      await fs.close(file);
    }
    const body: ProviderReplaceRequest = {
      bootId: bootId,
      configRevision: configRevision,
      kind: kind,
      name: name,
      candidate: candidatePath
    };
    const response = await call(filesDir, http.RequestMethod.POST, '/arkclash/providers/replace',
      JSON.stringify(body), 30000);
    return parseRuntimeProvidersSnapshot(response);
  } catch (error) {
    throw new Error(runtimeProviderError(error as Object));
  } finally {
    if (candidatePath !== '') {
      await removeProfileFile(candidatePath).catch((): void => {});
    }
  }
}
