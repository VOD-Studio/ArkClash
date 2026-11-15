import { fileIo as fs } from '@kit.CoreFileKit';
import { Downloader } from './Download';
import { errorCode, errorString, ProfileError } from './Errors';
import {
  candidatePath, checkProfileCommit, findProfile, findSubscription, ProfileList, ProfileRecord, readListAsync, readOptionalText,
  removeProfileFile, sameSource, statePath, SubscriptionRecord, SubscriptionState, summaryPath, uniqueProfileName,
  withProfileStorage, writeList, writeProfileText, writeState, yamlPath
} from './Store';
import { analyze, ProfileSummary } from './Summary';

export interface UpdateEnv {
  filesDir: string;
  downloader: Downloader;
  running: () => string;
  // 成功返回表示内核已应用；资格检查由提交方在记账后执行。
  reload?: (path: string, profile: string, expectedProfile?: string) => Promise<void>;
  prefetch?: (path: string) => void;
  eligible?: () => boolean;
}

export interface ProfileCandidateChange {
  create?: ProfileRecord;
  subscription?: SubscriptionRecord;
  state?: SubscriptionState;
  expectedSubscription?: SubscriptionRecord;
  expectedContentRevision?: string;
  mutate?: (list: ProfileList) => void;
}

function checkCandidate(list: ProfileList, profile: string, change: ProfileCandidateChange,
  shouldCommit?: () => boolean): void {
  if (shouldCommit !== undefined && !shouldCommit()) {
    throw new ProfileError('canceled');
  }
  const record = findProfile(list, profile);
  if (change.create !== undefined) {
    if (record !== undefined) {
      throw new ProfileError('conflict');
    }
    if (change.subscription !== undefined && list.subscriptions.some((sub: SubscriptionRecord): boolean =>
      sub.url === change.subscription?.url)) {
      throw new ProfileError('link_exists');
    }
  } else if (record === undefined) {
    throw new ProfileError('not_found');
  }
  if (change.expectedSubscription !== undefined) {
    const actual = findSubscription(list, change.expectedSubscription.id);
    if (actual === undefined || record?.subscription !== actual.id) {
      throw new ProfileError('not_found');
    }
    if (!sameSource(actual, change.expectedSubscription)) {
      throw new ProfileError('conflict');
    }
  }
  if (record !== undefined && change.expectedContentRevision !== undefined &&
    (record.contentRevision ?? '') !== change.expectedContentRevision) {
    throw new ProfileError('conflict');
  }
}

async function restoreText(path: string, previous: string | undefined): Promise<void> {
  if (previous === undefined) {
    await removeProfileFile(path);
  } else {
    await writeProfileText(path, previous);
  }
}

// 调用方先取资源任务锁。下载与内核应用在短提交锁外，落盘前再次核对来源和操作代次。
export async function commitCandidate(env: UpdateEnv, profile: string, candidate: string,
  shouldCommit?: () => boolean, requestedChange?: ProfileCandidateChange): Promise<void> {
  const change: ProfileCandidateChange = requestedChange ?? {};
  const eligible = (): boolean => env.eligible?.() !== false && shouldCommit?.() !== false;
  checkProfileCommit(eligible);
  const target = yamlPath(env.filesDir, profile);
  const backup = candidatePath(env.filesDir, profile);
  let applied = false;
  let hadOriginal = false;
  let committed = false;
  try {
    const result = await analyze(candidate);
    if (result.error !== '') {
      throw new ProfileError(result.error);
    }
    const summary = JSON.parse(result.summary) as ProfileSummary;
    const list = await readListAsync(env.filesDir);
    checkCandidate(list, profile, change, eligible);
    change.mutate?.(list);
    const previousSummary = await readOptionalText(summaryPath(env.filesDir, profile));
    const unchanged = previousSummary !== undefined &&
      (JSON.parse(previousSummary) as ProfileSummary).revision === summary.revision;
    hadOriginal = await fs.access(target);
    if (hadOriginal) {
      await fs.copyFile(target, backup);
    }
    checkProfileCommit(eligible);
    if (!unchanged && env.reload !== undefined && env.running() === profile) {
      try { await env.reload(candidate, profile, profile); }
      catch (e) { throw new ProfileError(errorCode(errorString(e as Object)) === 'conflict' ? 'conflict' : 'rejected'); }
      applied = true;
      checkProfileCommit(eligible);
    }
    await withProfileStorage<void>(env.filesDir, async (): Promise<void> => {
      const latest = await readListAsync(env.filesDir);
      checkCandidate(latest, profile, change, eligible);
      const oldList = JSON.stringify(latest);
      change.mutate?.(latest);
      const oldSummary = await readOptionalText(summaryPath(env.filesDir, profile));
      const subscription = change.subscription ?? change.expectedSubscription ??
        findSubscription(latest, findProfile(latest, profile)?.subscription ?? '');
      const oldState = subscription !== undefined ?
        await readOptionalText(statePath(env.filesDir, subscription.id)) : undefined;
      checkProfileCommit(eligible);
      let replaced = false;
      try {
        if (subscription !== undefined && change.state === undefined) {
          const previous = oldState !== undefined ? JSON.parse(oldState) as SubscriptionState :
            { updatedAt: 0, failures: 0 } as SubscriptionState;
          previous.updatedAt = Date.now();
          change.state = previous;
        }
        await writeProfileText(summaryPath(env.filesDir, profile), result.summary, eligible);
        if (subscription !== undefined && change.state !== undefined) {
          const merged = oldState !== undefined ? JSON.parse(oldState) as SubscriptionState : change.state;
          merged.updatedAt = change.state.updatedAt;
          merged.usage = change.state.usage;
          merged.name = change.state.name;
          merged.failures = 0;
          merged.error = undefined;
          merged.failedAt = undefined;
          change.state = merged;
          await writeState(env.filesDir, subscription.id, merged, eligible);
        }
        checkCandidate(latest, profile, change, eligible);
        await fs.rename(candidate, target);
        replaced = true;
        checkProfileCommit(eligible);
        const record = change.create ?? findProfile(latest, profile);
        if (record === undefined) {
          throw new ProfileError('not_found');
        }
        if (change.create !== undefined) {
          record.name = uniqueProfileName(latest, record.name || profile);
          latest.profiles.push(record);
          if (change.subscription !== undefined) {
            latest.subscriptions.push(change.subscription);
          }
          if (latest.current === '') {
            latest.current = profile;
          }
        }
        record.contentRevision = summary.revision;
        record.updatedAt = change.state?.updatedAt ?? Date.now();
        await writeList(env.filesDir, latest, eligible);
        checkProfileCommit(eligible);
        committed = true;
      } catch (e) {
        if (replaced) {
          if (hadOriginal) {
            await fs.rename(backup, target);
          } else {
            await removeProfileFile(target);
          }
        }
        await restoreText(summaryPath(env.filesDir, profile), oldSummary);
        if (subscription !== undefined) {
          await restoreText(statePath(env.filesDir, subscription.id), oldState);
        }
        await writeProfileText(`${env.filesDir}/profiles/list.json`, oldList);
        const code = errorCode(errorString(e as Object));
        throw new ProfileError(['canceled', 'conflict', 'not_found', 'corrupt'].includes(code) ? code : 'io');
      }
    });
    if (env.prefetch !== undefined && env.running() !== profile) {
      env.prefetch(target);
    }
  } catch (e) {
    if (applied && !committed && hadOriginal && env.reload !== undefined) {
      try {
        await env.reload(target, profile, profile);
      } catch (restoreError) {
        throw new ProfileError('apply_failed');
      }
    }
    throw e as Error;
  } finally {
    await removeProfileFile(candidate);
    await removeProfileFile(backup);
  }
}
