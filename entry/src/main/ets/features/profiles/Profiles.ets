// 配置管理的界面状态（#35）。未连接时订阅由本进程更新；连接中交给 VPN 进程，本进程只写列表（ADR-0009）。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { getRunningProfile, prefetchProfile, reloadProfile } from '../../client/Controller';
import { connection } from '../../client/Connection';
import { addViaVpn, notifyListChanged, ProfileEvent, ProfileEvents, updateViaVpn } from '../../client/ProfileCommands';
import { ensureDir, hasFile, listDir, removeFile, writeText } from '../../shared/Files';
import { DirectDownloader, hostOf } from '../../shared/profiles/Download';
import { errorString, ProfileError } from '../../shared/profiles/Errors';
import {
  candidatePath,
  DEFAULT_INTERVAL_HOURS,
  emptyList,
  findProfile,
  findSubscription,
  LIST_VERSION,
  listPath,
  newId,
  ProfileList,
  ProfileRecord,
  profilesDir,
  readList,
  readState,
  statePath,
  SubscriptionRecord,
  SubscriptionState,
  SubscriptionUsage,
  summaryPath,
  writeList,
  yamlPath
} from '../../shared/profiles/Store';
import { AnalyzeResult } from '../../shared/profiles/Analyze';
import { analyze, ProfileSummary, readSummary, writeSummary } from '../../shared/profiles/Summary';
import {
  commitCandidate,
  downloadNewSubscription,
  UpdateEnv,
  UpdateOutcome,
  UpdateScheduler
} from '../../shared/profiles/Updater';

export { SubscriptionUsage } from '../../shared/profiles/Store';

// 0.3.0 只有一份来自订阅的配置，元数据在 preferences 里，首次启动新版本时迁移（#35）。
const LEGACY_PREF_URL = 'subscriptionUrl';
const LEGACY_PREF_NAME = 'profileName';
const LEGACY_PREF_UPDATED_AT = 'profileUpdatedAt';
const LEGACY_PREF_USAGE = 'profileUsage';
const LEGACY_PROFILE = 'default.yaml';

/** 一份配置在界面上的样子：列表里的记录，加上它的订阅和订阅状态。 */
@ObservedV2
export class ProfileItem {
  @Trace id: string = '';
  @Trace name: string = '';
  @Trace nameEdited: boolean = false;
  @Trace subscription: string = ''; // 空串 = 本地配置
  @Trace url: string = '';
  @Trace autoUpdate: boolean = true;
  @Trace intervalHours: number = DEFAULT_INTERVAL_HOURS;
  @Trace state: SubscriptionState = { updatedAt: 0, failures: 0 };
  @Trace updating: boolean = false;

  get isSubscription(): boolean {
    return this.subscription !== '';
  }
}

/** 编辑面板提交的内容；本地配置只用 name。 */
export interface ProfileEdit {
  name: string;
  url: string;
  autoUpdate: boolean;
  intervalHours: number;
}

/** 界面自己的校验错误，和 Errors.ets 的格式一样由 ProfileErrors.ets 翻译。 */
export const ERR_NAME_TAKEN = 'name_taken';
export const ERR_NAME_EMPTY = 'name_empty';
export const ERR_LINK_EXISTS = 'link_exists';
export const ERR_INTERVAL = 'interval_invalid';
export const ERR_IN_USE = 'in_use';

// 就地更新已有的对象：进行中的标记和界面上的引用都保留。
function fillItem(item: ProfileItem, record: ProfileRecord, list: ProfileList, filesDir: string): ProfileItem {
  item.id = record.id;
  item.name = record.name;
  item.nameEdited = record.nameEdited;
  item.subscription = record.subscription;
  const sub = record.subscription !== '' ? findSubscription(list, record.subscription) : undefined;
  if (sub !== undefined) {
    item.url = sub.url;
    item.autoUpdate = sub.autoUpdate;
    item.intervalHours = sub.intervalHours;
    item.state = readState(filesDir, sub.id);
  } else {
    item.url = '';
    item.state = { updatedAt: 0, failures: 0 };
  }
  return item;
}

// 本地文件名去掉目录和扩展名，作为本地配置的默认名称。
function fileNameOf(uri: string): string {
  const last = uri.split('/').pop() ?? uri;
  let name = last;
  try {
    name = decodeURIComponent(last);
  } catch (e) {
    name = last;
  }
  return name.replace(/\.(ya?ml)$/i, '');
}

@ObservedV2
export class ProfileStore {
  @Trace items: ProfileItem[] = [];
  @Trace current: string = ''; // 列表里的当前配置
  @Trace running: string = ''; // 连接中内核正在运行的配置；未连接时为空串
  @Trace connected: boolean = false;
  @Trace summary: ProfileSummary | undefined = undefined; // 生效那份配置的摘要
  @Trace updatingAll: boolean = false;
  // 正在热切换过去的配置。界面先把选中标记移过去，切换在后台进行，失败再退回（FlClash 的做法）。
  @Trace pending: string = '';
  private list: ProfileList = emptyList();
  private filesDir: string = '';
  private context?: common.UIAbilityContext;
  private foreground: boolean = true;
  private orphansCleaned: boolean = false;
  // 未连接且应用在前台时，由这个进程按到期时间更新订阅。
  private scheduler?: UpdateScheduler;
  private events: ProfileEvents = new ProfileEvents((event: ProfileEvent) => this.onEvent(event));

  /** 首帧前同步调用：只读几个小文件，摘要异步读。 */
  load(context: common.UIAbilityContext): void {
    this.context = context;
    this.filesDir = context.filesDir;
    try {
      this.migrateLegacy(context);
    } catch (e) {
      // 迁移失败不能挡住启动：旧文件还在，下次启动再试；这次按没有配置显示。
      hilog.error(0x0A11, 'ProfileStore', 'migrate 0.3.0 profile failed: %{public}s', (e as Error).message);
    }
    this.list = readList(this.filesDir);
    this.rebuild();
    this.scheduler = new UpdateScheduler(this.localEnv(), (outcome: UpdateOutcome) => this.applyOutcome(outcome));
    this.refreshSummary();
  }

  get ready(): boolean {
    return this.active() !== undefined;
  }

  /** 生效的配置：连接中是内核正在运行的，否则是当前配置。 */
  active(): ProfileItem | undefined {
    const id = this.connected && this.running !== '' ? this.running : this.current;
    return this.items.find((item: ProfileItem) => item.id === id);
  }

  /** 界面上标为选中的配置：热切换进行中时已经是目标配置。 */
  selectedId(): string {
    if (this.pending !== '') {
      return this.pending;
    }
    return this.connected && this.running !== '' ? this.running : this.current;
  }

  find(id: string): ProfileItem | undefined {
    return this.items.find((item: ProfileItem) => item.id === id);
  }

  /** 连接状态确定下来后由页面层调用（不含正在连接、正在断开）。 */
  setConnected(connected: boolean): void {
    if (connected === this.connected && (connected || this.orphansCleaned)) {
      return;
    }
    this.connected = connected;
    if (connected) {
      // 交接：不再发起新的更新，进行中的照常完成（ADR-0009）。
      this.scheduler?.stop(false);
      getRunningProfile(this.filesDir).then((profile: string) => {
        this.running = profile;
        this.refreshSummary();
      }).catch(() => {});
    } else {
      this.running = '';
      this.reloadFromDisk();
      this.cleanOrphans().then(() => this.syncScheduler());
    }
    this.syncEvents();
    this.refreshSummary();
  }

  /** 应用进入前台或后台。后台不更新、不订阅推送。 */
  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (foreground) {
      // 连接期间 VPN 进程可能更新过订阅，回到前台时重读一遍。
      this.reloadFromDisk();
    }
    this.syncScheduler();
    this.syncEvents();
  }

  // ---- 添加 ----

  /** 添加订阅；成功返回 undefined，失败返回错误（ProfileErrors.ets 翻译）。 */
  async addSubscription(rawUrl: string): Promise<string | undefined> {
    const url = rawUrl.trim();
    if (this.list.subscriptions.some((s: SubscriptionRecord) => s.url === url)) {
      return ERR_LINK_EXISTS;
    }
    const profile = newId('p');
    const subscription = newId('s');
    ensureDir(profilesDir(this.filesDir));
    let outcome: UpdateOutcome;
    try {
      outcome = await this.viaVpnOrLocal(
        () => addViaVpn(this.filesDir, profile, subscription, url),
        () => downloadNewSubscription(this.localEnv(), profile, subscription, url));
    } catch (e) {
      return errorString(e as Error);
    }
    if (!outcome.ok) {
      return outcome.error ?? 'network';
    }
    const record: ProfileRecord = {
      id: profile,
      name: this.uniqueName(outcome.state.name ?? hostOf(url), ''),
      nameEdited: false,
      subscription: subscription
    };
    const sub: SubscriptionRecord = {
      id: subscription,
      url: url,
      autoUpdate: true,
      intervalHours: DEFAULT_INTERVAL_HOURS
    };
    this.list.subscriptions.push(sub);
    await this.addRecord(record);
    return undefined;
  }

  /** 从系统文件选择器导入本地 YAML。用户取消时返回 undefined。 */
  async importLocal(): Promise<string | undefined> {
    const uri = await this.pickFile();
    if (uri === undefined) {
      return undefined;
    }
    const profile = newId('p');
    ensureDir(profilesDir(this.filesDir));
    try {
      await this.copyIntoCandidate(uri, profile);
    } catch (e) {
      return errorString(e as Error);
    }
    const record: ProfileRecord = {
      id: profile,
      name: this.uniqueName(fileNameOf(uri), ''),
      nameEdited: false,
      subscription: ''
    };
    await this.addRecord(record);
    return undefined;
  }

  /** 替换本地配置的内容；正在运行的先让内核解析并切换（ADR-0010）。 */
  async replaceLocal(id: string): Promise<string | undefined> {
    const item = this.find(id);
    if (item === undefined || item.isSubscription) {
      return 'not_found';
    }
    const uri = await this.pickFile();
    if (uri === undefined) {
      return undefined;
    }
    item.updating = true;
    try {
      await this.copyIntoCandidate(uri, id);
    } catch (e) {
      return errorString(e as Error);
    } finally {
      item.updating = false;
    }
    if (this.active()?.id === id) {
      this.refreshSummary();
    }
    return undefined;
  }

  // ---- 更新 ----

  /** 手动更新一个订阅。失败原因同时记在卡片上（状态文件）。 */
  async update(id: string): Promise<string | undefined> {
    const item = this.find(id);
    if (item === undefined || !item.isSubscription || item.updating) {
      return undefined;
    }
    item.updating = true;
    try {
      const subscription = item.subscription;
      const outcome = await this.viaVpnOrLocal(
        () => updateViaVpn(this.filesDir, subscription),
        () => this.scheduler!.update(subscription));
      this.applyOutcome(outcome);
      return outcome.ok ? undefined : outcome.error;
    } catch (e) {
      return errorString(e as Error);
    } finally {
      item.updating = false;
    }
  }

  /** 更新所有订阅，不论是否开着自动更新。逐个进行，每张卡片各自显示结果。 */
  async updateAll(): Promise<void> {
    if (this.updatingAll) {
      return;
    }
    this.updatingAll = true;
    try {
      for (const item of this.items.filter((i: ProfileItem) => i.isSubscription)) {
        await this.update(item.id);
      }
    } finally {
      this.updatingAll = false;
    }
  }

  // ---- 切换 ----

  /**
   * 设为当前配置。连接中就是热切换：成功才改列表，失败留在原配置并返回原因（ADR-0010）。
   * 同一时间只切换一次，切换中再点别的卡片会被忽略。
   */
  async select(id: string): Promise<string | undefined> {
    const item = this.find(id);
    if (item === undefined || this.pending !== '') {
      return undefined;
    }
    if (!this.connected) {
      if (this.current !== id) {
        // 先同步改界面状态，调用方放在 animateTo 里时能渐变过去。
        this.current = id;
        this.list.current = id;
        await this.saveList(false);
        this.refreshSummary();
      }
      return undefined;
    }
    if (this.running === id) {
      return undefined;
    }
    this.pending = id;
    try {
      await reloadProfile(this.filesDir, id, yamlPath(this.filesDir, id));
      this.running = id;
      this.list.current = id;
      await this.saveList(false);
      this.refreshSummary();
      return undefined;
    } catch (e) {
      return new ProfileError('rejected', (e as Error).message).message;
    } finally {
      this.pending = '';
    }
  }

  // ---- 编辑和删除 ----

  async edit(id: string, edit: ProfileEdit): Promise<string | undefined> {
    const item = this.find(id);
    const record = findProfile(this.list, id);
    if (item === undefined || record === undefined) {
      return 'not_found';
    }
    const name = edit.name.trim();
    if (name.length === 0) {
      return ERR_NAME_EMPTY;
    }
    if (name !== record.name && this.items.some((i: ProfileItem) => i.id !== id && i.name === name)) {
      return ERR_NAME_TAKEN;
    }
    const sub = item.isSubscription ? findSubscription(this.list, item.subscription) : undefined;
    if (sub !== undefined) {
      const interval = Math.floor(edit.intervalHours);
      if (!Number.isFinite(interval) || interval < 1) {
        return ERR_INTERVAL;
      }
      const url = edit.url.trim();
      if (url !== sub.url) {
        if (this.list.subscriptions.some((s: SubscriptionRecord) => s.id !== sub.id && s.url === url)) {
          return ERR_LINK_EXISTS;
        }
        // 改链接后立即用新链接更新，成功才保存新链接（#35）。
        item.updating = true;
        try {
          const subscription = sub.id;
          const outcome = await this.viaVpnOrLocal(
            () => updateViaVpn(this.filesDir, subscription, url),
            () => this.scheduler!.update(subscription, url));
          if (!outcome.ok) {
            return outcome.error ?? 'network';
          }
          this.applyOutcome(outcome);
        } catch (e) {
          return errorString(e as Error);
        } finally {
          item.updating = false;
        }
        sub.url = url;
      }
      sub.autoUpdate = edit.autoUpdate;
      sub.intervalHours = interval;
    }
    if (name !== record.name) {
      record.name = name;
      record.nameEdited = true;
    }
    await this.saveList(sub !== undefined);
    return undefined;
  }

  /** 连接中不能删正在运行的配置（#35）。 */
  canRemove(id: string): boolean {
    return !(this.connected && this.running === id);
  }

  async remove(id: string): Promise<string | undefined> {
    const record = findProfile(this.list, id);
    if (record === undefined) {
      return undefined;
    }
    if (!this.canRemove(id)) {
      return ERR_IN_USE;
    }
    this.list.profiles = this.list.profiles.filter((p: ProfileRecord) => p.id !== id);
    if (record.subscription !== '') {
      this.list.subscriptions = this.list.subscriptions.filter((s: SubscriptionRecord) => s.id !== record.subscription);
    }
    if (this.list.current === id) {
      this.list.current = this.list.profiles.length > 0 ? this.list.profiles[0].id : '';
    }
    await this.saveList(record.subscription !== '');
    await removeFile(yamlPath(this.filesDir, id));
    await removeFile(summaryPath(this.filesDir, id));
    if (record.subscription !== '') {
      await removeFile(statePath(this.filesDir, record.subscription));
    }
    this.refreshSummary();
    return undefined;
  }

  // ---- 内部 ----

  private localEnv(): UpdateEnv {
    return {
      filesDir: this.filesDir,
      downloader: new DirectDownloader(),
      running: () => '',
      reload: undefined
    };
  }

  // 本地配置的导入和替换：连接中正在运行的那份要先过内核，其余的让内核预下载 rule-provider。
  private importEnv(): UpdateEnv {
    if (!this.connected) {
      return this.localEnv();
    }
    return {
      filesDir: this.filesDir,
      downloader: new DirectDownloader(),
      running: () => this.running,
      reload: (path: string, profile: string) => reloadProfile(this.filesDir, profile, path),
      prefetch: (path: string) => {
        prefetchProfile(this.filesDir, path).catch(() => {});
      }
    };
  }

  /**
   * 连接中交给 VPN 进程，未连接时自己做。命令连不上 controller 时重新探测：确认已断开就自己做，
   * 其他错误照常抛出（ADR-0009）。
   */
  private async viaVpnOrLocal(remote: () => Promise<UpdateOutcome>,
    local: () => Promise<UpdateOutcome>): Promise<UpdateOutcome> {
    if (!this.connected) {
      return await local();
    }
    try {
      return await remote();
    } catch (e) {
      const stillConnected = this.context !== undefined ? await connection.recheck(this.context) : true;
      if (stillConnected) {
        throw e as Error;
      }
      this.setConnected(false);
      return await local();
    }
  }

  private async pickFile(): Promise<string | undefined> {
    if (this.context === undefined) {
      return undefined;
    }
    const documentPicker = new picker.DocumentViewPicker(this.context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['YAML|.yaml,.yml'];
    const uris = await documentPicker.select(options);
    return uris.length > 0 ? uris[0] : undefined;
  }

  // 选中的文件复制进沙箱，之后和原文件无关（#35）。
  private async copyIntoCandidate(uri: string, profile: string): Promise<void> {
    const candidate = candidatePath(this.filesDir, profile);
    try {
      const source = await fs.open(uri, fs.OpenMode.READ_ONLY);
      try {
        await fs.copyFile(source.fd, candidate);
      } finally {
        await fs.close(source);
      }
    } catch (e) {
      await removeFile(candidate);
      throw new ProfileError('io', (e as Error).message);
    }
    await commitCandidate(this.importEnv(), profile, candidate);
  }

  private async addRecord(record: ProfileRecord): Promise<void> {
    this.list.profiles.push(record);
    if (this.list.current === '' || findProfile(this.list, this.list.current) === undefined) {
      this.list.current = record.id;
    }
    await this.saveList(record.subscription !== '');
    this.refreshSummary();
  }

  /** 名称不重复：重复时自动加序号。exclude 是正在改名的配置自己。 */
  private uniqueName(base: string, exclude: string): string {
    const taken = (name: string) => this.list.profiles.some((p: ProfileRecord) => p.id !== exclude && p.name === name);
    if (!taken(base)) {
      return base;
    }
    let n = 2;
    while (taken(`${base} ${n}`)) {
      n++;
    }
    return `${base} ${n}`;
  }

  /** 写列表并刷新界面；subscriptionsChanged 时让负责更新的一方重新安排。 */
  private async saveList(subscriptionsChanged: boolean): Promise<void> {
    await writeList(this.filesDir, this.list);
    this.rebuild();
    if (!subscriptionsChanged) {
      return;
    }
    if (this.connected) {
      notifyListChanged(this.filesDir).catch(() => {});
    } else {
      this.scheduler?.reschedule();
    }
  }

  // 列表或状态文件变了之后同步界面状态。
  private rebuild(): void {
    const previous = this.items;
    this.items = this.list.profiles.map((record: ProfileRecord) => {
      const old = previous.find((p: ProfileItem) => p.id === record.id);
      return fillItem(old ?? new ProfileItem(), record, this.list, this.filesDir);
    });
    this.current = this.list.current;
  }

  private reloadFromDisk(): void {
    if (this.filesDir === '') {
      return;
    }
    this.list = readList(this.filesDir);
    this.rebuild();
    this.syncNames();
  }

  /** 一次更新的结果：刷新那张卡片，生效的配置还要刷新摘要。 */
  private applyOutcome(outcome: UpdateOutcome): void {
    const item = this.items.find((i: ProfileItem) => i.subscription === outcome.subscription);
    if (item === undefined) {
      return;
    }
    item.state = outcome.state;
    this.syncNames();
    if (outcome.ok && this.active()?.id === item.id) {
      this.refreshSummary();
    }
  }

  // 没改过名的配置跟随机场给的名字。列表只有界面写，VPN 进程的更新结果在这里同步（#35）。
  private syncNames(): void {
    let changed = false;
    for (const record of this.list.profiles) {
      if (record.nameEdited || record.subscription === '') {
        continue;
      }
      const name = readState(this.filesDir, record.subscription).name;
      if (name === undefined) {
        continue;
      }
      const wanted = this.uniqueName(name, record.id);
      if (wanted !== record.name) {
        record.name = wanted;
        changed = true;
      }
    }
    if (changed) {
      this.saveList(false).catch(() => {});
    }
  }

  private onEvent(event: ProfileEvent): void {
    if (event.type === 'reloaded' && event.profile !== undefined) {
      this.running = event.profile;
      this.refreshSummary();
    } else if (event.type === 'updated' && event.subscription !== undefined) {
      const subscription = event.subscription;
      this.applyOutcome({
        subscription: subscription,
        ok: event.ok === true,
        state: readState(this.filesDir, subscription)
      });
    }
  }

  private refreshSummary(): void {
    const item = this.active();
    if (item === undefined) {
      this.summary = undefined;
      return;
    }
    const id = item.id;
    readSummary(this.filesDir, id).then((summary: ProfileSummary | undefined) => {
      if (this.active()?.id === id) {
        this.summary = summary;
      }
    });
  }

  private syncScheduler(): void {
    if (!this.connected && this.foreground && this.orphansCleaned) {
      this.scheduler?.start();
    } else {
      this.scheduler?.stop(false);
    }
  }

  private syncEvents(): void {
    if (this.connected && this.foreground) {
      this.events.start(this.filesDir);
    } else {
      this.events.stop();
    }
  }

  // 列表里没有的文件：添加订阅时界面在 VPN 进程回复前被杀留下的，或者没提交的候选文件（ADR-0009）。
  // 只在未连接时清理，这时没有别的进程在写这个目录。
  private async cleanOrphans(): Promise<void> {
    if (this.orphansCleaned) {
      return;
    }
    this.orphansCleaned = true;
    const keep = new Set<string>(['list.json']);
    for (const p of this.list.profiles) {
      keep.add(`${p.id}.yaml`);
      keep.add(`${p.id}.summary.json`);
    }
    for (const s of this.list.subscriptions) {
      keep.add(`${s.id}.state.json`);
    }
    const dir = profilesDir(this.filesDir);
    for (const name of await listDir(dir)) {
      if (!keep.has(name)) {
        await removeFile(`${dir}/${name}`);
      }
    }
  }

  private migrateLegacy(context: common.UIAbilityContext): void {
    const legacy = `${profilesDir(this.filesDir)}/${LEGACY_PROFILE}`;
    if (hasFile(listPath(this.filesDir)) || !hasFile(legacy)) {
      return;
    }
    const prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    const url = prefs.getSync(LEGACY_PREF_URL, '') as string;
    const profile = newId('p');
    const record: ProfileRecord = {
      id: profile,
      name: (prefs.getSync(LEGACY_PREF_NAME, '') as string) || (url !== '' ? hostOf(url) : 'default'),
      nameEdited: false,
      subscription: ''
    };
    const list: ProfileList = { version: LIST_VERSION, current: profile, profiles: [record], subscriptions: [] };
    if (url !== '') {
      const subscription = newId('s');
      record.subscription = subscription;
      list.subscriptions.push({
        id: subscription,
        url: url,
        autoUpdate: true,
        intervalHours: DEFAULT_INTERVAL_HOURS
      });
      const usage = prefs.getSync(LEGACY_PREF_USAGE, '') as string;
      const state: SubscriptionState = {
        updatedAt: prefs.getSync(LEGACY_PREF_UPDATED_AT, 0) as number,
        usage: usage.length > 0 ? JSON.parse(usage) as SubscriptionUsage : undefined,
        failures: 0
      };
      writeText(statePath(this.filesDir, subscription), JSON.stringify(state));
    }
    fs.renameSync(legacy, yamlPath(this.filesDir, profile));
    writeText(listPath(this.filesDir), JSON.stringify(list));
    // 摘要在后台生成，生成好之前首页按「连接后显示」处理。
    analyze(yamlPath(this.filesDir, profile)).then((result: AnalyzeResult) => {
      if (result.error === '') {
        writeSummary(this.filesDir, profile, result.summary).then(() => this.refreshSummary());
      }
    });
    prefs.deleteSync(LEGACY_PREF_URL);
    prefs.deleteSync(LEGACY_PREF_NAME);
    prefs.deleteSync(LEGACY_PREF_UPDATED_AT);
    prefs.deleteSync(LEGACY_PREF_USAGE);
    prefs.flush();
  }
}
