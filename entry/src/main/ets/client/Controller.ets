// 内核 controller 的一次性查询和设置；推送类数据（流量等）在 Traffic.ets。
import { http } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';

const TIMEOUT_MS = 3000;
// 能选出实际节点的代理组类型，见 mihomo adapter/outboundgroup。
const GROUP_TYPES: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance'];

export type OutboundMode = 'rule' | 'global' | 'direct';

interface ModeBody {
  mode: string;
}

interface ErrorBody {
  message?: string;
}

export interface RuntimeStatus {
  profile: string;
  running: boolean;
  intent: 'started' | 'stopped';
  forward: 'stopped' | 'preparing' | 'running' | 'paused' | 'failed';
  sessionMode: 'tun' | 'proxyOnly';
  listenersOpen: boolean;
  tunAttached: boolean;
  vpnCreated: boolean;
  startedAt: number;
  bootId: string;
  revision: number;
  configRevision: number;
  version: string;
  mode: OutboundMode;
}

interface ReloadBody {
  profile: string;
  path: string;
  expectedProfile?: string;
}

interface DelayHistory {
  delay: number;
}

interface ProxyInfo {
  name: string;
  type: string;
  testUrl?: string;
  url?: string;
  history?: DelayHistory[];
  hidden?: boolean;
  icon?: string;
}

interface ProxySummaryReference {
  id: string;
  name: string;
}

interface ProxiesResponse {
  proxies: Record<string, ProxySummaryReference>;
  nodes: Record<string, ProxyInfo>;
  members: Record<string, ProxySummaryReference[]>;
  actual: Record<string, string>;
  retired?: Record<string, boolean>;
}

/** 代理组概况：主代理组（配置里排第一的组）当前选中的节点，以及全部组名。delay 为 0 表示还没测过或超时。 */
export interface GroupSummary {
  group: string;
  node: string;
  delay: number;
  retired: boolean;
  groups: string[]; // 按配置顺序
  groupIcons?: Record<string, string>;
}

/** 非 2xx 时抛出 Error，message 优先用响应里的 message（ArkClash 自有接口的错误格式）。 */
export async function call(filesDir: string, method: http.RequestMethod, path: string, body?: string,
  timeoutMs: number = TIMEOUT_MS): Promise<string> {
  const runtime = await readRuntime(filesDir);
  if (runtime === undefined) {
    throw new Error('core is not running');
  }
  const request = http.createHttp();
  try {
    const header: Record<string, string> = {
      'Authorization': `Bearer ${runtime.secret}`,
      'Content-Type': 'application/json'
    };
    const response = await request.request(`http://${CONTROLLER_ADDRESS}${path}`, {
      method: method,
      header: header,
      extraData: body,
      connectTimeout: TIMEOUT_MS,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      let message: string | undefined;
      try {
        message = (JSON.parse(response.result as string) as ErrorBody).message;
      } catch (e) {
        message = undefined;
      }
      throw new Error(message ?? `controller ${path}: HTTP ${response.responseCode}`);
    }
    return response.result as string;
  } finally {
    request.destroy();
  }
}

// /configs 的字段名带连字符（mixed-port），按 Record 读。
async function configs(filesDir: string): Promise<Record<string, Object>> {
  return JSON.parse(await call(filesDir, http.RequestMethod.GET, '/configs')) as Record<string, Object>;
}

export async function getMode(filesDir: string): Promise<OutboundMode> {
  return ((await configs(filesDir))['mode'] as string).toLowerCase() as OutboundMode;
}

/** 立即改运行中的内核，热切换后也保持（ADR-0010）。下次连接用的值由 Connection 写进 runtime.json。 */
export async function setMode(filesDir: string, mode: OutboundMode): Promise<void> {
  const body: ModeBody = { mode: mode };
  await call(filesDir, http.RequestMethod.PATCH, '/arkclash/configs', JSON.stringify(body));
}

export async function getAllowLan(filesDir: string): Promise<boolean> {
  return ((await configs(filesDir))['allow-lan'] as boolean | undefined) ?? false;
}

/** 局域网内其他设备能否连本机的代理端口。和 setMode 一样，热切换后保持。 */
export async function setAllowLan(filesDir: string, allow: boolean): Promise<void> {
  const body: Record<string, boolean> = { 'allow-lan': allow };
  await call(filesDir, http.RequestMethod.PATCH, '/arkclash/configs', JSON.stringify(body));
}

/** 正在运行的配置编号（ADR-0010）。 */
export async function getRunningProfile(filesDir: string): Promise<string> {
  return (await getRuntimeStatus(filesDir)).profile;
}

export async function getRuntimeStatus(filesDir: string): Promise<RuntimeStatus> {
  return JSON.parse(await call(filesDir, http.RequestMethod.GET, '/arkclash/status')) as RuntimeStatus;
}

/** 在后台预先下载 path 里的 rule-provider（core/prefetch.go）。 */
export async function prefetchProfile(filesDir: string, path: string): Promise<void> {
  const body: Record<string, string> = { 'path': path };
  await call(filesDir, http.RequestMethod.POST, '/arkclash/prefetch', JSON.stringify(body), 120000);
}

/** 热切换到 path（配置目录下的文件）；内核解析失败时抛出它的错误信息，原配置不变。 */
export async function reloadProfile(filesDir: string, profile: string, path: string,
  expectedProfile?: string): Promise<void> {
  const body: ReloadBody = { profile: profile, path: path, expectedProfile: expectedProfile };
  // 新配置里有没下载过的 proxy-provider 时，内核要等它下载完。
  await call(filesDir, http.RequestMethod.POST, '/arkclash/reload', JSON.stringify(body), 60000);
}

/** 局域网共享所用的 HTTP 代理端口，0 表示未开放；出口与服务探测使用 /arkclash/probe。 */
export async function getProxyPort(filesDir: string): Promise<number> {
  const c = await configs(filesDir);
  const mixed = (c['mixed-port'] as number | undefined) ?? 0;
  return mixed > 0 ? mixed : (c['port'] as number | undefined) ?? 0;
}

export async function getMainGroup(filesDir: string): Promise<GroupSummary | undefined> {
  const mode = await getMode(filesDir);
  if (mode === 'direct') {
    return undefined;
  }
  const graph = JSON.parse(await call(filesDir, http.RequestMethod.GET, '/arkclash/proxies')) as ProxiesResponse;
  const isGroup = (name: string): boolean => {
    const ref = graph.proxies[name];
    return ref !== undefined && GROUP_TYPES.includes(graph.nodes[ref.id]?.type ?? '');
  };
  const order = graph.members['GLOBAL']?.map((ref: ProxySummaryReference): string => ref.name) ?? Object.keys(graph.proxies);
  const visible = order.filter((name: string): boolean => name !== 'GLOBAL' && isGroup(name) &&
    graph.nodes[graph.proxies[name].id].hidden !== true);
  const groups = mode === 'global' && isGroup('GLOBAL') ? ['GLOBAL', ...visible] : visible;
  if (groups.length === 0) {
    return undefined;
  }
  let groupIcons: Record<string, string> | undefined;
  for (const name of groups) {
    const icon = graph.nodes[graph.proxies[name].id].icon;
    if (icon !== undefined && icon !== '') {
      if (groupIcons === undefined) { groupIcons = {}; }
      groupIcons[name] = icon;
    }
  }
  const group = groups[0];
  let actualId = graph.actual[group] ?? '';
  let node: ProxyInfo | undefined = graph.nodes[actualId];
  let retired = graph.retired?.[actualId] === true;
  const seen: Set<string> = new Set<string>([group]);
  while (node !== undefined && GROUP_TYPES.includes(node.type)) {
    if (seen.has(node.name)) {
      node = undefined;
      break;
    }
    seen.add(node.name);
    actualId = graph.actual[node.name] ?? '';
    retired = retired || graph.retired?.[actualId] === true;
    node = graph.nodes[actualId];
  }
  const history = node?.history ?? [];
  const delay = history.length > 0 ? history[history.length - 1].delay : 0;
  const summary: GroupSummary = { group: group, node: node?.name ?? '', delay: delay, retired: retired, groups: groups };
  if (groupIcons !== undefined) { summary.groupIcons = groupIcons; }
  return summary;
}
