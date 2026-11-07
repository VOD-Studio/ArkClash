// filesDir/profiles/ 下的文件格式，界面进程和 VPN 进程共用（#35）：
//   list.json             订阅和配置的记录、顺序、当前配置。只有界面写。
//   <配置编号>.yaml        配置内容。来自订阅的由更新方写（未连接时界面、连接中 VPN 进程），本地配置只有界面写。
//   <配置编号>.summary.json 配置摘要，和 YAML 同一个写入方。
//   <订阅编号>.state.json   订阅的用量、上次更新时间、失败原因，和 YAML 同一个写入方。
// core/lib.go 的热切换只接受这个目录下的文件。
import { ensureDir, readTextSync, writeTextAsync } from '../Files';

export const LIST_VERSION = 1;
export const DEFAULT_INTERVAL_HOURS = 24;

export interface SubscriptionRecord {
  id: string;
  url: string;
  autoUpdate: boolean;
  intervalHours: number; // 最少 1
}

export interface ProfileRecord {
  id: string;
  name: string;
  nameEdited: boolean; // 用户改过名，更新时不再用机场给的名字覆盖
  subscription: string; // 订阅编号，空串 = 本地配置
}

export interface ProfileList {
  version: number;
  current: string; // 当前配置的编号；连接中真正在跑的以 VPN 进程为准（ADR-0010）
  profiles: ProfileRecord[]; // 按添加顺序
  subscriptions: SubscriptionRecord[];
}

/** 机场在 subscription-userinfo 头里给的用量，字节；expire 是秒级时间戳，0 = 未知或不过期。 */
export interface SubscriptionUsage {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

export interface SubscriptionState {
  updatedAt: number; // 上次成功的时间，毫秒；0 = 还没成功过
  usage?: SubscriptionUsage;
  name?: string; // 上次响应头给的名字；列表只有界面写，由界面同步到没改过名的配置上
  error?: string; // 上次失败的原因（Errors.ets 的格式），成功后清除
  failedAt?: number;
  failures: number; // 连续失败次数，决定下次重试的间隔
}

export function profilesDir(filesDir: string): string {
  return `${filesDir}/profiles`;
}

export function listPath(filesDir: string): string {
  return `${profilesDir(filesDir)}/list.json`;
}

export function yamlPath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${profile}.yaml`;
}

/**
 * 下载或导入的内容先放这里，检查通过（正在运行的还要先过内核）才改名成正式的 YAML。
 * 每次都不同：交接的瞬间两个进程可能同时更新同一个订阅。
 */
export function candidatePath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${newId(profile + '.')}.candidate`;
}

export function summaryPath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${profile}.summary.json`;
}

export function statePath(filesDir: string, subscription: string): string {
  return `${profilesDir(filesDir)}/${subscription}.state.json`;
}

export function newId(prefix: string): string {
  return `${prefix}${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
}

export function emptyList(): ProfileList {
  return { version: LIST_VERSION, current: '', profiles: [], subscriptions: [] };
}

export function readList(filesDir: string): ProfileList {
  const text = readTextSync(listPath(filesDir));
  if (text === undefined) {
    return emptyList();
  }
  try {
    return JSON.parse(text) as ProfileList;
  } catch (e) {
    return emptyList();
  }
}

/** 只有界面进程调用。 */
export async function writeList(filesDir: string, list: ProfileList): Promise<void> {
  ensureDir(profilesDir(filesDir));
  await writeTextAsync(listPath(filesDir), JSON.stringify(list));
}

export function readState(filesDir: string, subscription: string): SubscriptionState {
  const text = readTextSync(statePath(filesDir, subscription));
  if (text !== undefined) {
    try {
      return JSON.parse(text) as SubscriptionState;
    } catch (e) {
      // 按没有状态处理
    }
  }
  return { updatedAt: 0, failures: 0 };
}

export async function writeState(filesDir: string, subscription: string, state: SubscriptionState): Promise<void> {
  await writeTextAsync(statePath(filesDir, subscription), JSON.stringify(state));
}

export function findProfile(list: ProfileList, id: string): ProfileRecord | undefined {
  return list.profiles.find((p: ProfileRecord) => p.id === id);
}

export function findSubscription(list: ProfileList, id: string): SubscriptionRecord | undefined {
  return list.subscriptions.find((s: SubscriptionRecord) => s.id === id);
}

export function profileOfSubscription(list: ProfileList, subscription: string): ProfileRecord | undefined {
  return list.profiles.find((p: ProfileRecord) => p.subscription === subscription);
}
