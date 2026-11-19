import { taskpool } from '@kit.ArkTS';
import { newId, profilesDir, readOptionalText, withProfileStorage, writeProfileText } from './Store';
import { checkProxyFilterSnapshot, proxyFilterPresets, ProxyFilterPreset, ProxyFilterSnapshot } from './ProxyFilterModel';

export {
  newProxyFilter, PROXY_FILTER_EXPRESSION_LIMIT, PROXY_FILTER_LABEL_LIMIT, proxyFilterProblem,
  ProxyFilterPreset, ProxyFilterSnapshot, searchProxyFilters
} from './ProxyFilterModel';

function proxyFilterPath(filesDir: string): string { return `${profilesDir(filesDir)}/proxy-filters.json`; }

@Concurrent
function decodeProxyFilters(text: string): ProxyFilterSnapshot {
  return checkProxyFilterSnapshot(JSON.parse(text) as ProxyFilterSnapshot);
}

@Concurrent
function encodeProxyFilters(snapshot: ProxyFilterSnapshot): string {
  return JSON.stringify(checkProxyFilterSnapshot(snapshot));
}

export async function readProxyFilters(filesDir: string): Promise<ProxyFilterSnapshot> {
  const text = await readOptionalText(proxyFilterPath(filesDir));
  return text === undefined ? { revision: 'default', presets: proxyFilterPresets() } :
    await taskpool.execute(decodeProxyFilters, text) as ProxyFilterSnapshot;
}

export function commitProxyFilters(filesDir: string, expectedRevision: string,
  presets: ProxyFilterPreset[]): Promise<ProxyFilterSnapshot> {
  return withProfileStorage<ProxyFilterSnapshot>(filesDir, async (): Promise<ProxyFilterSnapshot> => {
    const current = await readProxyFilters(filesDir);
    if (current.revision !== expectedRevision) { throw new Error('proxy_filter_conflict'); }
    const snapshot: ProxyFilterSnapshot = { revision: newId('r'), presets: presets };
    await writeProfileText(proxyFilterPath(filesDir), await taskpool.execute(encodeProxyFilters, snapshot) as string);
    return snapshot;
  });
}
