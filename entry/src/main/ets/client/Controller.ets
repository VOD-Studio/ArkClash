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

interface DelayHistory {
  delay: number;
}

interface ProxyInfo {
  type: string;
  now?: string;
  all?: string[];
  history?: DelayHistory[];
}

interface ProxiesResponse {
  proxies: Record<string, ProxyInfo>;
}

/** 代理组概况：主代理组（配置里排第一的组）当前选中的节点，以及全部组名。delay 为 0 表示还没测过或超时。 */
export interface GroupSummary {
  group: string;
  node: string;
  delay: number;
  groups: string[]; // 按配置顺序
}

async function call(filesDir: string, method: http.RequestMethod, path: string, body?: string): Promise<string> {
  const runtime = readRuntime(filesDir);
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
      readTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(`controller ${path}: HTTP ${response.responseCode}`);
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

/** 只改运行中的内核；重连后由 Connection 重新下发用户选的模式。 */
export async function setMode(filesDir: string, mode: OutboundMode): Promise<void> {
  const body: ModeBody = { mode: mode };
  await call(filesDir, http.RequestMethod.PATCH, '/configs', JSON.stringify(body));
}

export async function getAllowLan(filesDir: string): Promise<boolean> {
  return ((await configs(filesDir))['allow-lan'] as boolean | undefined) ?? false;
}

/** 局域网内其他设备能否连本机的代理端口。只改运行中的内核；重连后由 Connection 重新下发。 */
export async function setAllowLan(filesDir: string, allow: boolean): Promise<void> {
  const body: Record<string, boolean> = { 'allow-lan': allow };
  await call(filesDir, http.RequestMethod.PATCH, '/configs', JSON.stringify(body));
}

/** 内核的 HTTP 代理端口，0 = 配置里没开。UI 进程不走 VPN，要经过代理时只能用这个端口。 */
export async function getProxyPort(filesDir: string): Promise<number> {
  const c = await configs(filesDir);
  const mixed = (c['mixed-port'] as number | undefined) ?? 0;
  return mixed > 0 ? mixed : (c['port'] as number | undefined) ?? 0;
}

export async function getMainGroup(filesDir: string): Promise<GroupSummary | undefined> {
  const proxies = (JSON.parse(await call(filesDir, http.RequestMethod.GET, '/proxies')) as ProxiesResponse).proxies;
  const isGroup = (name: string): boolean => {
    const p = proxies[name];
    return p !== undefined && GROUP_TYPES.includes(p.type);
  };
  // GLOBAL 的 all 按配置文件里的顺序列出所有组和节点。
  const order = proxies['GLOBAL']?.all ?? Object.keys(proxies);
  const groups = order.filter((name: string) => name !== 'GLOBAL' && isGroup(name));
  if (groups.length === 0) {
    return undefined;
  }
  const group = groups[0];
  // 组里选的可能还是组，一直跟到实际节点。
  let node = proxies[group].now ?? '';
  for (let depth = 0; depth < 8 && isGroup(node); depth++) {
    node = proxies[node].now ?? '';
  }
  const history = proxies[node]?.history ?? [];
  const delay = history.length > 0 ? history[history.length - 1].delay : 0;
  return { group: group, node: node, delay: delay, groups: groups };
}
