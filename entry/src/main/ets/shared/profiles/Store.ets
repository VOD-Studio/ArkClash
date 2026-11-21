// 保留现有 profiles 文件布局；UI 与 VPN 的短提交共用文件锁，网络不持有该锁。
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ProfileError } from './Errors';

export const LIST_VERSION = 1;
export const DEFAULT_INTERVAL_MINUTES = 1440;
export const DEFAULT_INTERVAL_HOURS = 24;

export interface SubscriptionRecord {
  id: string;
  url: string;
  autoUpdate: boolean;
  intervalHours: number;
  intervalMinutes?: number;
  ageSecretKey?: string;
  revision?: string;
}

export interface ProfileRecord {
  id: string;
  name: string;
  nameEdited: boolean;
  subscription: string;
  contentRevision?: string;
  updatedAt?: number;
  type?: string;
}

export interface ProfileList {
  version: number;
  current: string;
  profiles: ProfileRecord[];
  subscriptions: SubscriptionRecord[];
  revision?: string;
}

export interface SubscriptionUsage {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

export interface SubscriptionState {
  updatedAt: number;
  usage?: SubscriptionUsage;
  name?: string;
  error?: string;
  failedAt?: number;
  failures: number;
}

const storageQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();
const activeTasks: Set<string> = new Set<string>();

export function profilesDir(filesDir: string): string {
  return `${filesDir}/profiles`;
}

export async function profileDataPath(filesDir: string, file: string): Promise<string> {
  const home = await fs.access(`${profilesDir(filesDir)}/.backup-store`) ? profilesDir(filesDir) : filesDir;
  return `${home}/${file}`;
}

export function profileWorkDir(filesDir: string): string {
  return `${filesDir}/profile-work`;
}

export function listPath(filesDir: string): string {
  return `${profilesDir(filesDir)}/list.json`;
}

export function validProfileId(id: string): boolean {
  return typeof id === 'string' && new RegExp('^[A-Za-z0-9_.-]+$').test(id) && id !== '.' && id !== '..';
}

function checkedId(id: string): string {
  if (!validProfileId(id)) {
    throw new ProfileError('corrupt');
  }
  return id;
}

export function yamlPath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${checkedId(profile)}.yaml`;
}

export function candidatePath(filesDir: string, profile: string): string {
  return `${profileWorkDir(filesDir)}/${newId(checkedId(profile) + '.')}.candidate`;
}

export function summaryPath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${checkedId(profile)}.summary.json`;
}

export function statePath(filesDir: string, subscription: string): string {
  return `${profilesDir(filesDir)}/${checkedId(subscription)}.state.json`;
}

export function selectedPath(filesDir: string, profile: string): string {
  return `${profilesDir(filesDir)}/${checkedId(profile)}.selected.json`;
}

export function newId(prefix: string): string {
  return `${prefix}${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
}

export function emptyList(): ProfileList {
  return { version: LIST_VERSION, current: '', profiles: [], subscriptions: [] };
}

export function missingFile(error: Object): boolean {
  const code = (error as BusinessError).code;
  return code === 13900002 || code === 2;
}

export async function ensureProfilesDir(filesDir: string): Promise<void> {
  await ensureProfileDirectory(profilesDir(filesDir));
  await ensureProfileDirectory(profileWorkDir(filesDir));
}

async function ensureProfileDirectory(path: string): Promise<void> {
  if (await fs.access(path)) { return; }
  try {
    await fs.mkdir(path, true);
  } catch (_error) {
    if (!(await fs.access(path))) { throw new ProfileError('io'); }
  }
}

export async function readOptionalText(path: string): Promise<string | undefined> {
  try {
    return await fs.readText(path);
  } catch (e) {
    if (missingFile(e as Object)) {
      return undefined;
    }
    throw new ProfileError('io');
  }
}

export async function removeProfileFile(path: string): Promise<void> {
  try {
    await fs.unlink(path);
  } catch (e) {
    if (!missingFile(e as Object)) {
      throw new ProfileError('io');
    }
  }
}

export function checkProfileCommit(shouldCommit?: () => boolean): void {
  if (shouldCommit?.() === false) { throw new ProfileError('canceled'); }
}

export async function writeProfileText(path: string, text: string, shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  const previous = shouldCommit === undefined ? undefined : await readOptionalText(path);
  checkProfileCommit(shouldCommit);
  const temporary = `${path}.${newId('')}.tmp`;
  let replaced = false;
  try {
    const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const bytes = new util.TextEncoder().encodeInto(text);
      const written = await fs.write(file.fd, bytes.buffer);
      if (written !== bytes.byteLength) {
        throw new ProfileError('io');
      }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
    checkProfileCommit(shouldCommit);
    await fs.rename(temporary, path);
    replaced = true;
    checkProfileCommit(shouldCommit);
  } catch (e) {
    if (replaced) {
      if (previous === undefined) { await removeProfileFile(path); }
      else { await writeProfileText(path, previous); }
    }
    if ((e as Error).message === 'canceled') { throw e as Error; }
    throw new ProfileError('io');
  } finally {
    await removeProfileFile(temporary);
  }
}

function parseList(text: string): ProfileList {
  try {
    const list = JSON.parse(text) as ProfileList;
    if (list === null || list.version !== LIST_VERSION || typeof list.current !== 'string' ||
      !Array.isArray(list.profiles) || !Array.isArray(list.subscriptions)) {
      throw new ProfileError('corrupt');
    }
    const ids = new Set<string>();
    const subscriptions = new Set<string>();
    for (const sub of list.subscriptions) {
      if (sub === null || !validProfileId(sub.id) || subscriptions.has(sub.id) ||
        typeof sub.url !== 'string' || typeof sub.autoUpdate !== 'boolean' ||
        (sub.ageSecretKey !== undefined && typeof sub.ageSecretKey !== 'string') ||
        !Number.isFinite(intervalMinutes(sub)) || intervalMinutes(sub) < 1) {
        throw new ProfileError('corrupt');
      }
      subscriptions.add(sub.id);
    }
    for (const profile of list.profiles) {
      if (profile === null || !validProfileId(profile.id) || ids.has(profile.id) ||
        typeof profile.name !== 'string' || typeof profile.nameEdited !== 'boolean' ||
        typeof profile.subscription !== 'string' ||
        (profile.subscription !== '' && !subscriptions.has(profile.subscription))) {
        throw new ProfileError('corrupt');
      }
      ids.add(profile.id);
    }
    if (list.current !== '' && !ids.has(list.current)) {
      throw new ProfileError('corrupt');
    }
    return list;
  } catch (e) {
    throw new ProfileError('corrupt');
  }
}

// VPN 启动阶段保留同步入口；界面使用 readListAsync。
export function readList(filesDir: string): ProfileList {
  try {
    return parseList(fs.readTextSync(listPath(filesDir)));
  } catch (e) {
    if (missingFile(e as Object)) {
      return emptyList();
    }
    throw e as Error;
  }
}

export async function readListAsync(filesDir: string): Promise<ProfileList> {
  return readProfileListFile(listPath(filesDir));
}

export async function readProfileListFile(path: string): Promise<ProfileList> {
  const text = await readOptionalText(path);
  return text === undefined ? emptyList() : parseList(text);
}

export async function writeList(filesDir: string, list: ProfileList, shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  await ensureProfilesDir(filesDir);
  list.revision = newId('r');
  await writeProfileText(listPath(filesDir), JSON.stringify(list), shouldCommit);
}

function parseState(text: string): SubscriptionState {
  try {
    const state = JSON.parse(text) as SubscriptionState;
    if (state === null || !Number.isFinite(state.updatedAt) || state.updatedAt < 0 ||
      !Number.isFinite(state.failures) || state.failures < 0) {
      throw new ProfileError('corrupt');
    }
    return state;
  } catch (e) {
    throw new ProfileError('corrupt');
  }
}

export function readState(filesDir: string, subscription: string): SubscriptionState {
  try {
    return parseState(fs.readTextSync(statePath(filesDir, subscription)));
  } catch (e) {
    if (missingFile(e as Object)) {
      return { updatedAt: 0, failures: 0 };
    }
    throw e as Error;
  }
}

export async function readStateAsync(filesDir: string, subscription: string): Promise<SubscriptionState> {
  const text = await readOptionalText(statePath(filesDir, subscription));
  return text === undefined ? { updatedAt: 0, failures: 0 } : parseState(text);
}

export async function writeState(filesDir: string, subscription: string, state: SubscriptionState,
  shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  await ensureProfilesDir(filesDir);
  await writeProfileText(statePath(filesDir, subscription), JSON.stringify(state), shouldCommit);
}

export async function readSelected(filesDir: string, profileId: string): Promise<Record<string, string>> {
  const text = await readOptionalText(selectedPath(filesDir, profileId));
  if (text === undefined) {
    return {};
  }
  try {
    const selected = JSON.parse(text) as Record<string, Object>;
    if (selected === null || typeof selected !== 'object' || Array.isArray(selected)) {
      throw new ProfileError('corrupt');
    }
    for (const group of Object.keys(selected)) {
      const name = selected[group];
      if (typeof name !== 'string') {
        throw new ProfileError('corrupt');
      }
    }
    return selected as Record<string, string>;
  } catch (e) {
    throw new ProfileError('corrupt');
  }
}

export async function writeSelected(filesDir: string, profileId: string,
  selected: Record<string, string>, shouldCommit?: () => boolean): Promise<void> {
  checkProfileCommit(shouldCommit);
  await withProfileStorage<void>(filesDir, async (): Promise<void> => {
    checkProfileCommit(shouldCommit);
    const list = await readListAsync(filesDir);
    if (findProfile(list, profileId) === undefined) {
      throw new ProfileError('not_found');
    }
    await readSelected(filesDir, profileId);
    await writeProfileText(selectedPath(filesDir, profileId), JSON.stringify(selected), shouldCommit);
  });
}

export async function withProfileStorage<T>(filesDir: string, operation: () => Promise<T>): Promise<T> {
  return withProfileDataLock<T>(filesDir, async (): Promise<T> => {
    await ensureProfilesDir(filesDir);
    return operation();
  });
}

export async function withProfileDataLock<T>(filesDir: string, operation: () => Promise<T>): Promise<T> {
  const previous = storageQueues.get(filesDir) ?? Promise.resolve();
  let release: () => void = (): void => {};
  const gate = new Promise<void>((resolve: () => void): void => { release = resolve; });
  const queued = previous.then((): Promise<void> => gate);
  storageQueues.set(filesDir, queued);
  await previous;
  let file: fs.File | undefined = undefined;
  try {
    file = await fs.open(`${filesDir}/.profile-storage.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    await file.lock(true);
    return await operation();
  } finally {
    try {
      if (file !== undefined) {
        await fs.close(file);
      }
    } finally {
      release();
      if (storageQueues.get(filesDir) === queued) {
        storageQueues.delete(filesDir);
      }
    }
  }
}

// 资源任务锁独立于短提交锁；tryLock 防止交接时另一进程重复发起同一下载。
export async function withProfileTask<T>(filesDir: string, resource: string,
  operation: () => Promise<T>): Promise<T> {
  const identity = `${filesDir}:${checkedId(resource)}`;
  if (activeTasks.has(identity)) { throw new ProfileError('busy'); }
  activeTasks.add(identity);
  let file: fs.File | undefined = undefined;
  try {
    await ensureProfilesDir(filesDir);
    file = await fs.open(`${profileWorkDir(filesDir)}/.${resource}.task.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    try { file.tryLock(true); } catch (e) { throw new ProfileError('busy'); }
    return await operation();
  } finally {
    try { if (file !== undefined) { await fs.close(file); } }
    finally { activeTasks.delete(identity); }
  }
}

export function intervalMinutes(sub: SubscriptionRecord): number {
  return sub.intervalMinutes ?? sub.intervalHours * 60;
}

export function findProfile(list: ProfileList, id: string): ProfileRecord | undefined {
  return list.profiles.find((profile: ProfileRecord): boolean => profile.id === id);
}

export function findSubscription(list: ProfileList, id: string): SubscriptionRecord | undefined {
  return list.subscriptions.find((subscription: SubscriptionRecord): boolean => subscription.id === id);
}

export function profileOfSubscription(list: ProfileList, subscription: string): ProfileRecord | undefined {
  return list.profiles.find((profile: ProfileRecord): boolean => profile.subscription === subscription);
}

export function uniqueProfileName(list: ProfileList, base: string, exclude: string = ''): string {
  const preferred = base.trim().slice(0, 64);
  const taken = (name: string): boolean =>
    list.profiles.some((profile: ProfileRecord): boolean => profile.id !== exclude && profile.name === name);
  if (!taken(preferred)) {
    return preferred;
  }
  let suffix = 1;
  while (true) {
    const ending = `(${suffix})`;
    const name = `${preferred.slice(0, 64 - ending.length)}${ending}`;
    if (!taken(name)) {
      return name;
    }
    suffix++;
  }
}

export function sameSource(actual: SubscriptionRecord, expected: SubscriptionRecord): boolean {
  return actual.id === expected.id && actual.url === expected.url &&
    (actual.ageSecretKey ?? '') === (expected.ageSecretKey ?? '') &&
    (actual.revision ?? '') === (expected.revision ?? '');
}
