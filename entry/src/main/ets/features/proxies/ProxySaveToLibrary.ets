import { common } from '@kit.AbilityKit';
import { fetchRuntimeProxyDefinition, validateProxyDefinitions } from '../../client/LocalProxyCore';
import {
  checkProxyName, LocalProxy, LocalProxySnapshot, localProxyName, localProxyProblem
} from '../../shared/profiles/LocalProxies';
import { ProxyDefinition, proxyText, withProxyValue } from '../../shared/profiles/LocalProxySchema';
import { readLocalProxies, saveLocalProxy } from '../../shared/profiles/LocalProxyStore';
import { ProxyNodeView } from './ProxyView';

const NON_EXPORTABLE_TYPES: string[] = [
  'Direct', 'Reject', 'RejectDrop', 'Compatible', 'Pass', 'Dns',
  'DIRECT', 'REJECT', 'REJECT-DROP', 'COMPATIBLE', 'PASS', 'DNS'
];

export interface SaveProxyConflict {
  existingId: string;
  existingName: string;
  suggestedName: string;
  definition: ProxyDefinition;
  snapshot: LocalProxySnapshot;
}

export interface SaveProxyAttempt {
  status: 'saved' | 'conflict';
  savedName: string;
  conflict?: SaveProxyConflict;
}

export function isExportableProxyNode(node: ProxyNodeView): boolean {
  if (!node.online || node.nested || node.leafRetired || node.type === '') {
    return false;
  }
  return !NON_EXPORTABLE_TYPES.includes(node.type);
}

export function suggestUniqueProxyName(snapshot: LocalProxySnapshot, baseName: string): string {
  const trimmed = baseName.trim();
  const used = new Set<string>(snapshot.proxies.map((item: LocalProxy): string => localProxyName(item)));
  for (let suffix = 2; suffix < 10000; suffix++) {
    const tag = ` (${suffix})`;
    const stem = trimmed.length + tag.length > 255 ? trimmed.slice(0, 255 - tag.length).trim() : trimmed;
    const candidate = `${stem}${tag}`;
    if (!used.has(candidate)) {
      return candidate;
    }
  }
  return `${trimmed.slice(0, 240)} (${Date.now()})`;
}

export function proxySaveErrorText(code: string): Resource {
  switch (code) {
    case 'proxy_stale_config': return $r('app.string.proxy_save_err_stale');
    case 'proxy_not_found': return $r('app.string.proxy_save_err_not_found');
    case 'proxy_not_exportable': return $r('app.string.proxy_save_err_not_exportable');
    case 'local_proxy_name_taken': return $r('app.string.proxy_save_err_name_taken');
    case 'local_proxy_conflict': return $r('app.string.proxy_save_err_conflict');
    case 'local_proxy_store': return $r('app.string.proxy_save_err_store');
    case 'local_proxy_rejected':
    case 'local_proxy_type':
    case 'local_proxy_port':
    case 'local_proxy_required':
    case 'local_proxy_name_empty':
    case 'local_proxy_name_format':
    case 'local_proxy_name_reserved':
    case 'local_proxy_server_length':
      return $r('app.string.proxy_save_err_invalid');
    default:
      return $r('app.string.proxy_save_err_failed');
  }
}

export async function prepareSaveRuntimeProxy(context: common.UIAbilityContext, bootId: string,
  configRevision: number, nodeId: string, groupName: string): Promise<SaveProxyAttempt> {
  const fetched = await fetchRuntimeProxyDefinition(context.filesDir, bootId, configRevision, nodeId, groupName);
  const definition = fetched.definition;
  const problem = localProxyProblem(definition);
  if (problem !== '') {
    throw new Error(problem);
  }
  const checks = await validateProxyDefinitions(context, [definition], false);
  if (checks.length === 0 || checks[0] !== '') {
    throw new Error(checks[0] || 'local_proxy_rejected');
  }
  const snapshot = await readLocalProxies(context.filesDir);
  const name = proxyText(definition, ['name']).trim();
  const duplicate = checkProxyName(snapshot, definition, '');
  if (duplicate === '') {
    await saveLocalProxy(context.filesDir, snapshot, '', definition, []);
    return { status: 'saved', savedName: name };
  }
  const existing = snapshot.proxies.find((item: LocalProxy): boolean => localProxyName(item) === name);
  return {
    status: 'conflict',
    savedName: '',
    conflict: {
      existingId: existing?.id ?? '',
      existingName: name,
      suggestedName: suggestUniqueProxyName(snapshot, name),
      definition: definition,
      snapshot: snapshot
    }
  };
}

export async function resolveSaveProxyConflict(context: common.UIAbilityContext, conflict: SaveProxyConflict,
  mode: 'overwrite' | 'rename', customName?: string): Promise<string> {
  const latest = await readLocalProxies(context.filesDir);
  if (mode === 'overwrite') {
    const existing = latest.proxies.find((item: LocalProxy): boolean => localProxyName(item) === conflict.existingName) ??
      latest.proxies.find((item: LocalProxy): boolean => item.id === conflict.existingId);
    const targetId = existing?.id ?? '';
    const checks = await validateProxyDefinitions(context, [conflict.definition], false);
    if (checks.length === 0 || checks[0] !== '') {
      throw new Error(checks[0] || 'local_proxy_rejected');
    }
    await saveLocalProxy(context.filesDir, latest, targetId, conflict.definition, []);
    return conflict.existingName;
  }
  const nextName = (customName ?? suggestUniqueProxyName(latest, conflict.existingName)).trim();
  const renamed = withProxyValue(conflict.definition, ['name'], nextName);
  const problem = localProxyProblem(renamed);
  if (problem !== '') {
    throw new Error(problem);
  }
  const duplicate = checkProxyName(latest, renamed, '');
  if (duplicate !== '') {
    throw new Error(duplicate);
  }
  const checks = await validateProxyDefinitions(context, [renamed], false);
  if (checks.length === 0 || checks[0] !== '') {
    throw new Error(checks[0] || 'local_proxy_rejected');
  }
  await saveLocalProxy(context.filesDir, latest, '', renamed, []);
  return nextName;
}
