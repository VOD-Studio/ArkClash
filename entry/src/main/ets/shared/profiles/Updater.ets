// 订阅更新：未连接时在界面进程里跑，连接中在 VPN 进程里跑，两边只在注入的 UpdateEnv 上不同
// （ADR-0009）。同一时刻只有一个进程更新，交接方式见 ADR-0009「写入方交接」。
import { moveFile, removeFile } from '../Files';
import { DownloadInfo, Downloader } from './Download';
import { errorCode, errorString, ProfileError } from './Errors';
import {
  candidatePath,
  ProfileList,
  profileOfSubscription,
  readList,
  readState,
  findSubscription,
  SubscriptionRecord,
  SubscriptionState,
  writeState,
  yamlPath
} from './Store';
import { analyze, writeSummary } from './Summary';

const HOUR_MS = 3600 * 1000;
// 失败后按 30 分钟、1 小时、2 小时……翻倍重试，最长不超过更新间隔（#35）。
const RETRY_BASE_MS = 30 * 60 * 1000;
// setTimeout 的上限约 24.8 天，更远的到期时间到点后重新算。
const MAX_TIMER_MS = 0x7fffffff;

export interface UpdateEnv {
  filesDir: string;
  downloader: Downloader;
  /** 正在运行的配置编号；界面进程未连接时为空串。 */
  running: () => string;
  /** 让内核解析并切换到 path，解析失败时 reject。未连接时没有。 */
  reload?: (path: string, profile: string) => Promise<void>;
  /** 在后台预先下载 path 里的 rule-provider，第一次切换到它时不用等（core/prefetch.go）。未连接时没有。 */
  prefetch?: (path: string) => void;
}

export interface UpdateOutcome {
  subscription: string;
  ok: boolean;
  error?: string; // Errors.ets 的格式
  state: SubscriptionState;
}

/**
 * 把 candidate 提交为 profile 的内容：内容检查，正在运行的先让内核解析并切换（ADR-0010），
 * 再改名替换 YAML、写摘要。失败时抛出 ProfileError，原来的文件不动；candidate 总会被删掉。
 * shouldCommit 返回 false 时放弃（进程正在停止）。
 */
export async function commitCandidate(env: UpdateEnv, profile: string, candidate: string,
  shouldCommit?: () => boolean): Promise<void> {
  try {
    const result = await analyze(candidate);
    if (result.error !== '') {
      throw new Error(result.error);
    }
    if (shouldCommit !== undefined && !shouldCommit()) {
      throw new ProfileError('busy');
    }
    if (env.reload !== undefined && env.running() === profile) {
      try {
        await env.reload(candidate, profile);
      } catch (e) {
        throw new ProfileError('rejected', (e as Error).message);
      }
    }
    await moveFile(candidate, yamlPath(env.filesDir, profile));
    await writeSummary(env.filesDir, profile, result.summary);
    if (env.prefetch !== undefined && env.running() !== profile) {
      env.prefetch(yamlPath(env.filesDir, profile));
    }
  } finally {
    await removeFile(candidate);
  }
}

/** 下载 url 作为 profile 的新内容，流程同 commitCandidate。 */
export async function downloadProfile(env: UpdateEnv, profile: string, url: string,
  shouldCommit?: () => boolean): Promise<DownloadInfo> {
  const candidate = candidatePath(env.filesDir, profile);
  let info: DownloadInfo;
  try {
    info = await env.downloader.download(url, candidate);
  } catch (e) {
    await removeFile(candidate);
    throw e as Error;
  }
  await commitCandidate(env, profile, candidate, shouldCommit);
  return info;
}

function successState(info: DownloadInfo): SubscriptionState {
  return { updatedAt: Date.now(), usage: info.usage, name: info.name, failures: 0 };
}

/** 新加的订阅第一次下载：成功才写状态文件，失败什么都不留（#35「第一次下载成功才加入列表」）。 */
export async function downloadNewSubscription(env: UpdateEnv, profile: string, subscription: string,
  url: string): Promise<UpdateOutcome> {
  try {
    const info = await downloadProfile(env, profile, url);
    const state = successState(info);
    await writeState(env.filesDir, subscription, state);
    return { subscription: subscription, ok: true, state: state };
  } catch (e) {
    return { subscription: subscription, ok: false, error: errorString(e as Error), state: { updatedAt: 0, failures: 0 } };
  }
}

/**
 * 更新列表里的一个订阅并写状态文件。url 用于修改链接：用新链接下载，失败时不记失败，
 * 原来的链接和内容都保留；成功后由界面保存新链接（#35）。
 */
export async function updateSubscription(env: UpdateEnv, list: ProfileList, subscription: string, url?: string,
  shouldCommit?: () => boolean): Promise<UpdateOutcome> {
  const previous = readState(env.filesDir, subscription);
  const sub = findSubscription(list, subscription);
  const profile = profileOfSubscription(list, subscription);
  if (sub === undefined || profile === undefined) {
    return { subscription: subscription, ok: false, error: 'not_found', state: previous };
  }
  try {
    const info = await downloadProfile(env, profile.id, url ?? sub.url, shouldCommit);
    const state = successState(info);
    await writeState(env.filesDir, subscription, state);
    return { subscription: subscription, ok: true, state: state };
  } catch (e) {
    const error = errorString(e as Error);
    if (url !== undefined || errorCode(error) === 'busy') {
      return { subscription: subscription, ok: false, error: error, state: previous };
    }
    const state: SubscriptionState = {
      updatedAt: previous.updatedAt,
      usage: previous.usage,
      name: previous.name,
      error: error,
      failedAt: Date.now(),
      failures: previous.failures + 1
    };
    await writeState(env.filesDir, subscription, state);
    return { subscription: subscription, ok: false, error: error, state: state };
  }
}

/** 下次自动更新的时间（毫秒时间戳）；0 = 不自动更新。 */
export function nextDue(sub: SubscriptionRecord, state: SubscriptionState): number {
  if (!sub.autoUpdate) {
    return 0;
  }
  const interval = Math.max(1, sub.intervalHours) * HOUR_MS;
  if (state.failures > 0 && state.failedAt !== undefined) {
    return state.failedAt + Math.min(RETRY_BASE_MS * Math.pow(2, state.failures - 1), interval);
  }
  return state.updatedAt + interval;
}

/** 按到期时间调度自动更新（不是固定间隔扫描），手动更新也经过这里，同一个订阅不会同时更新两次。 */
export class UpdateScheduler {
  private env: UpdateEnv;
  private onUpdated: (outcome: UpdateOutcome) => void;
  private timer: number = -1;
  private stopped: boolean = true;
  private aborted: boolean = false;
  private runningDue: boolean = false;
  private inFlight: Map<string, Promise<UpdateOutcome>> = new Map();

  constructor(env: UpdateEnv, onUpdated: (outcome: UpdateOutcome) => void) {
    this.env = env;
    this.onUpdated = onUpdated;
  }

  /** 开始自动更新；已经到期的（包括启动前就到期的）马上更新。 */
  start(): void {
    this.stopped = false;
    this.aborted = false;
    this.reschedule();
  }

  /** 不再发起自动更新。abort 为 true 时进行中的更新也不再提交（VPN 进程停止时）。 */
  stop(abort: boolean): void {
    this.stopped = true;
    this.aborted = abort;
    this.clearTimer();
  }

  /** 列表变了（增删订阅、改间隔或开关）之后调用。 */
  reschedule(): void {
    this.clearTimer();
    if (this.stopped) {
      return;
    }
    const list = readList(this.env.filesDir);
    let earliest = 0;
    for (const sub of list.subscriptions) {
      const due = nextDue(sub, readState(this.env.filesDir, sub.id));
      if (due > 0 && (earliest === 0 || due < earliest)) {
        earliest = due;
      }
    }
    if (earliest === 0) {
      return;
    }
    const delay = Math.min(MAX_TIMER_MS, Math.max(0, earliest - Date.now()));
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.runDue();
    }, delay);
  }

  /** 手动更新；url 用于修改链接（见 updateSubscription）。 */
  update(subscription: string, url?: string): Promise<UpdateOutcome> {
    const key = url === undefined ? subscription : '';
    const existing = key !== '' ? this.inFlight.get(key) : undefined;
    if (existing !== undefined) {
      return existing;
    }
    const task = updateSubscription(this.env, readList(this.env.filesDir), subscription, url,
      () => !this.aborted).then((outcome: UpdateOutcome) => {
      this.onUpdated(outcome);
      return outcome;
    });
    if (key !== '') {
      this.inFlight.set(key, task);
      task.finally(() => this.inFlight.delete(key));
    }
    return task;
  }

  private clearTimer(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private async runDue(): Promise<void> {
    if (this.runningDue || this.stopped) {
      return;
    }
    this.runningDue = true;
    try {
      const list = readList(this.env.filesDir);
      for (const sub of list.subscriptions) {
        if (this.stopped) {
          break;
        }
        const due = nextDue(sub, readState(this.env.filesDir, sub.id));
        if (due > 0 && due <= Date.now()) {
          await this.update(sub.id);
        }
      }
    } finally {
      this.runningDue = false;
      this.reschedule();
    }
  }
}
