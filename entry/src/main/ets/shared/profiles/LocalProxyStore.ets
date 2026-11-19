import { taskpool } from '@kit.ArkTS';
import { newId, profilesDir, readOptionalText, withProfileStorage, writeProfileText } from './Store';
import { applyProxyLinkPlan, decodeProxyStore, emptyLocalProxies, encodeProxyStore, LocalProxy, LocalProxySnapshot,
  localProxyProblem, newLocalProxy, planProxyLinks, ProxyLinkPlan } from './LocalProxies';
import { ProxyDefinition, proxyText, withProxyValue } from './LocalProxySchema';

@Concurrent
function decodeStore(text: string): LocalProxySnapshot { return decodeProxyStore(text); }

@Concurrent
function encodeStore(snapshot: LocalProxySnapshot): string { return encodeProxyStore(snapshot); }

@Concurrent
function linksToPlan(snapshot: LocalProxySnapshot, links: string[], text: string): ProxyLinkPlan {
  return planProxyLinks(snapshot, links, text);
}

@Concurrent
function linksToProxies(snapshot: LocalProxySnapshot, links: string[], plan: ProxyLinkPlan,
  decoded: Map<number, ProxyDefinition[]>, originals: Map<string, ProxyDefinition>): LocalProxy[] {
  return applyProxyLinkPlan(snapshot, links, plan, decoded, originals);
}

export async function readProxyLinkPlan(snapshot: LocalProxySnapshot, links: string[], text: string):
  Promise<ProxyLinkPlan> {
  return await taskpool.execute(linksToPlan, snapshot, links, text) as ProxyLinkPlan;
}

export async function buildProxyLinkEdit(snapshot: LocalProxySnapshot, links: string[], plan: ProxyLinkPlan,
  decoded: Map<number, ProxyDefinition[]>, originals: Map<string, ProxyDefinition>): Promise<LocalProxy[]> {
  return await taskpool.execute(linksToProxies, snapshot, links, plan, decoded, originals) as LocalProxy[];
}

function localProxyPath(filesDir: string): string { return `${profilesDir(filesDir)}/local-proxies.json`; }

export async function readLocalProxies(filesDir: string): Promise<LocalProxySnapshot> {
  try {
    const text = await readOptionalText(localProxyPath(filesDir));
    return text === undefined ? emptyLocalProxies() :
      await taskpool.execute(decodeStore, text) as LocalProxySnapshot;
  } catch (error) {
    throw new Error('local_proxy_store');
  }
}

export function commitLocalProxies(filesDir: string, expected: LocalProxySnapshot,
  proxies: LocalProxy[]): Promise<LocalProxySnapshot> {
  return withProfileStorage<LocalProxySnapshot>(filesDir, async (): Promise<LocalProxySnapshot> => {
    const current = await readLocalProxies(filesDir);
    if (current.revision !== expected.revision) { throw new Error('local_proxy_conflict'); }
    const updated: LocalProxySnapshot = { version: 1, revision: newId('r'), proxies: proxies };
    const text = await taskpool.execute(encodeStore, updated) as string;
    await writeProfileText(localProxyPath(filesDir), text);
    return updated;
  });
}

export function saveLocalProxy(filesDir: string, snapshot: LocalProxySnapshot, id: string,
  definition: ProxyDefinition, emptyOptions: string[]): Promise<LocalProxySnapshot> {
  let normalized = withProxyValue(definition, ['name'], proxyText(definition, ['name']).trim());
  const port = proxyText(normalized, ['port']);
  const error = localProxyProblem(normalized);
  if (error !== '') { return Promise.reject(new Error(error)); }
  if (port !== '') { normalized = withProxyValue(normalized, ['port'], Number(port)); }
  // ArkUI 会观察表单数组，跨线程存储任务只接收普通值。
  const item = newLocalProxy(normalized, emptyOptions.slice(), id);
  const next = snapshot.proxies.slice();
  const index = next.findIndex((proxy: LocalProxy): boolean => proxy.id === id);
  if (id === '') { next.push(item); }
  else if (index < 0) { return Promise.reject(new Error('local_proxy_conflict')); }
  else { next[index] = item; }
  return commitLocalProxies(filesDir, snapshot, next);
}
