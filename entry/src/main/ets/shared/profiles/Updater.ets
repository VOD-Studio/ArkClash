import { DownloadInfo, hostOf } from './Download';
import { errorCode, errorString, ProfileError } from './Errors';
import {
  candidatePath, checkProfileCommit, DEFAULT_INTERVAL_HOURS, DEFAULT_INTERVAL_MINUTES, findProfile, findSubscription, intervalMinutes,
  newId, ProfileList, ProfileRecord, profileOfSubscription, readListAsync, readStateAsync,
  removeProfileFile, sameSource, SubscriptionRecord, SubscriptionState, withProfileStorage, withProfileTask, writeState
} from './Store';
import { commitCandidate, ProfileCandidateChange, UpdateEnv } from './Commit';
export { commitCandidate, ProfileCandidateChange, UpdateEnv } from './Commit';

const MINUTE_MS = 60000;
const CHECK_INTERVAL_MS = 20 * MINUTE_MS;

export interface UpdateOutcome {
  subscription: string;
  ok: boolean;
  error?: string;
  state: SubscriptionState;
}

export async function downloadProfile(env: UpdateEnv, profile: string, source: string,
  shouldCommit?: () => boolean, change?: ProfileCandidateChange): Promise<DownloadInfo> {
  const candidate = candidatePath(env.filesDir, profile);
  const eligible = (): boolean => env.eligible?.() !== false && shouldCommit?.() !== false;
  try {
    checkProfileCommit(eligible);
    const info = await env.downloader.download(source, candidate,
      { canceled: (): boolean => !eligible() });
    if (change !== undefined) {
      change.state = successState(info);
      if (change.create !== undefined && !change.create.nameEdited && info.name !== undefined) {
        change.create.name = info.name;
      }
    }
    await commitCandidate(env, profile, candidate, eligible, change);
    return info;
  } finally {
    await removeProfileFile(candidate);
  }
}

function successState(info: DownloadInfo): SubscriptionState {
  return { updatedAt: Date.now(), usage: info.usage ?? { upload: 0, download: 0, total: 0, expire: 0 },
    name: info.name, failures: 0 };
}

function sourceTaskKey(source: string): string {
  let hash = 2166136261;
  for (let index = 0; index < source.length; index++) { hash = Math.imul(hash ^ source.charCodeAt(index), 16777619); }
  return `source-${source.length}-${hash >>> 0}`;
}

export async function downloadNewSubscription(env: UpdateEnv, profile: string, subscription: string,
  source: string, label: string = '', shouldCommit?: () => boolean): Promise<UpdateOutcome> {
  const eligible = (): boolean => env.eligible?.() !== false && shouldCommit?.() !== false;
  try {
    return await withProfileTask<UpdateOutcome>(env.filesDir, sourceTaskKey(source), async (): Promise<UpdateOutcome> =>
      await withProfileTask<UpdateOutcome>(env.filesDir, profile, async (): Promise<UpdateOutcome> => {
      checkProfileCommit(eligible);
      const savedList = await readListAsync(env.filesDir);
      const saved = findProfile(savedList, profile);
      if (saved !== undefined) {
        if (saved.subscription !== subscription) { throw new ProfileError('conflict'); }
        return { subscription: subscription, ok: true, state: await readStateAsync(env.filesDir, subscription) };
      }
      if (savedList.subscriptions.some((item: SubscriptionRecord): boolean => item.url === source)) {
        throw new ProfileError('link_exists');
      }
      const sub: SubscriptionRecord = { id: subscription, url: source, autoUpdate: true,
        intervalHours: DEFAULT_INTERVAL_HOURS, intervalMinutes: DEFAULT_INTERVAL_MINUTES, revision: newId('s') };
      const record: ProfileRecord = { id: profile, name: label.trim() || hostOf(source) || profile,
        nameEdited: label.trim() !== '', subscription: subscription, type: 'url' };
      const change: ProfileCandidateChange = { create: record, subscription: sub };
      await downloadProfile(env, profile, source, eligible, change);
      return { subscription: subscription, ok: true, state: change.state ?? { updatedAt: 0, failures: 0 } };
      }));
  } catch (e) {
    return { subscription: subscription, ok: false, error: errorString(e as Object),
      state: { updatedAt: 0, failures: 0 } };
  }
}

export async function updateSubscription(env: UpdateEnv, list: ProfileList, subscription: string,
  source?: string, shouldCommit?: () => boolean): Promise<UpdateOutcome> {
  const eligible = (): boolean => env.eligible?.() !== false && shouldCommit?.() !== false;
  const previous = await readStateAsync(env.filesDir, subscription);
  const sub = findSubscription(list, subscription);
  const profile = profileOfSubscription(list, subscription);
  if (sub === undefined || profile === undefined) {
    return { subscription: subscription, ok: false, error: 'not_found', state: previous };
  }
  if (source !== undefined && source !== sub.url) {
    return { subscription: subscription, ok: false, error: 'conflict', state: previous };
  }
  const expected = JSON.parse(JSON.stringify(sub)) as SubscriptionRecord;
  const change: ProfileCandidateChange = { expectedSubscription: expected,
    expectedContentRevision: profile.contentRevision ?? '' };
  try {
    return await withProfileTask<UpdateOutcome>(env.filesDir, profile.id, async (): Promise<UpdateOutcome> => {
      await downloadProfile(env, profile.id, sub.url, eligible, change);
      return { subscription: subscription, ok: true, state: change.state ?? previous };
    });
  } catch (e) {
    const failure = errorString(e as Object);
    if (!eligible() || ['busy', 'canceled', 'conflict', 'not_found'].includes(errorCode(failure))) {
      return { subscription: subscription, ok: false, error: failure, state: previous };
    }
    return await withProfileStorage<UpdateOutcome>(env.filesDir, async (): Promise<UpdateOutcome> => {
      checkProfileCommit(eligible);
      const latest = await readListAsync(env.filesDir);
      const actual = findSubscription(latest, subscription);
      if (actual === undefined || !sameSource(actual, expected)) {
        return { subscription: subscription, ok: false, error: 'conflict', state: previous };
      }
      const saved = await readStateAsync(env.filesDir, subscription);
      const state = saved;
      state.error = failure;
      state.failedAt = Date.now();
      state.failures++;
      await writeState(env.filesDir, subscription, state, eligible);
      return { subscription: subscription, ok: false, error: failure, state: state };
    });
  }
}

export function nextDue(sub: SubscriptionRecord, state: SubscriptionState): number {
  if (!sub.autoUpdate) {
    return 0;
  }
  return state.updatedAt === 0 ? 1 : state.updatedAt + intervalMinutes(sub) * MINUTE_MS;
}

export class UpdateScheduler {
  private env: UpdateEnv;
  private onUpdated: (outcome: UpdateOutcome) => void;
  private timer: number = -1;
  private stopped: boolean = true;
  private generation: number = 0;
  private checking: boolean = false;
  private inFlight: Map<string, Promise<UpdateOutcome>> = new Map<string, Promise<UpdateOutcome>>();
  private inFlightSources: Map<string, string> = new Map<string, string>();
  private inFlightGenerations: Map<string, number> = new Map<string, number>();

  constructor(env: UpdateEnv, onUpdated: (outcome: UpdateOutcome) => void) {
    this.env = env;
    this.onUpdated = onUpdated;
  }

  start(): void {
    if (!this.stopped || this.env.eligible?.() === false) {
      return;
    }
    this.stopped = false;
    this.runDue().catch((): void => {});
  }

  stop(abort: boolean): void {
    this.stopped = true;
    if (abort) {
      this.generation++;
    }
    clearTimeout(this.timer);
    this.timer = -1;
  }

  operationGeneration(): number { return this.generation; }
  acceptsGeneration(generation: number): boolean { return generation === this.generation; }

  reschedule(): void {
    if (this.stopped || this.checking) {
      return;
    }
    clearTimeout(this.timer);
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.runDue().catch((): void => {});
    }, CHECK_INTERVAL_MS);
  }

  async update(subscription: string, source?: string): Promise<UpdateOutcome> {
    checkProfileCommit(this.env.eligible);
    const generation = this.generation;
    const list = await readListAsync(this.env.filesDir);
    if (generation !== this.generation) { throw new ProfileError('canceled'); }
    checkProfileCommit(this.env.eligible);
    const sub = findSubscription(list, subscription);
    const identity = `${sub?.url ?? ''}:${sub?.revision ?? ''}`;
    const existing = this.inFlight.get(subscription);
    if (existing !== undefined) {
      if (this.inFlightSources.get(subscription) === identity && this.inFlightGenerations.get(subscription) === generation) {
        return await existing;
      }
      await existing.catch((): void => {});
      return await this.update(subscription, source);
    }
    const task = this.runUpdate(subscription, generation, source);
    this.inFlight.set(subscription, task);
    this.inFlightSources.set(subscription, identity);
    this.inFlightGenerations.set(subscription, generation);
    const finished = (): void => {
      this.inFlight.delete(subscription);
      this.inFlightSources.delete(subscription);
      this.inFlightGenerations.delete(subscription);
    };
    task.then(finished, finished);
    return await task;
  }

  private async runUpdate(subscription: string, generation: number, source?: string): Promise<UpdateOutcome> {
    const list = await readListAsync(this.env.filesDir);
    if (generation !== this.generation) { throw new ProfileError('canceled'); }
    checkProfileCommit(this.env.eligible);
    const outcome = await updateSubscription(this.env, list, subscription, source,
      (): boolean => generation === this.generation && this.env.eligible?.() !== false);
    if (generation === this.generation && this.env.eligible?.() !== false) {
      this.onUpdated(outcome);
    }
    return outcome;
  }

  private async runDue(): Promise<void> {
    if (this.checking || this.stopped || this.env.eligible?.() === false) {
      return;
    }
    this.checking = true;
    const generation = this.generation;
    try {
      const list = await readListAsync(this.env.filesDir);
      for (const sub of list.subscriptions) {
        if (this.stopped || generation !== this.generation || this.env.eligible?.() === false) {
          break;
        }
        try {
          const due = nextDue(sub, await readStateAsync(this.env.filesDir, sub.id));
          if (this.stopped || generation !== this.generation || this.env.eligible?.() === false) { break; }
          if (due > 0 && due <= Date.now()) { await this.update(sub.id); }
        } catch (e) {
          // 坏单项保留原文件，不能阻断其余订阅；页面读取时会显示损坏错误。
        }
      }
    } finally {
      this.checking = false;
      if (generation !== this.generation && !this.stopped && this.env.eligible?.() !== false) {
        this.runDue().catch((): void => {});
      } else { this.reschedule(); }
    }
  }
}
