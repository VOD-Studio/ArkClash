import { common } from '@kit.AbilityKit';
import { getRuntimeStatus, prefetchProfile, reloadProfile, RuntimeStatus } from '../../client/Controller';
import { connection } from '../../client/Connection';
import { addViaVpn, notifyListChanged, ProfileEvent, ProfileEvents, updateViaVpn } from '../../client/ProfileCommands';
import { DirectDownloader, hostOf, validSubscriptionUrl } from '../../shared/profiles/Download';
import { errorString, ProfileError } from '../../shared/profiles/Errors';
import {
  candidatePath, checkProfileCommit, ensureProfilesDir, findProfile, newId,
  ProfileRecord, readListAsync, removeProfileFile, SubscriptionRecord, withProfileStorage,
  withProfileTask, writeList, writeProfileText, yamlPath
} from '../../shared/profiles/Store';
import { analyze, ProfileSummary, readSummary } from '../../shared/profiles/Summary';
import { commitCandidate, downloadNewSubscription, ProfileCandidateChange, UpdateEnv, UpdateOutcome,
  UpdateScheduler } from '../../shared/profiles/Updater';
import { parseProfileLinks, readSourceText, removeSavedProfile, saveProfileEdit, saveProfileOrder } from './ProfileActions';
import { pickDocumentFile, documentFileName } from '../../client/DocumentPicker';
import { ProfileBatchJob, runProfileBatch } from './ProfileBatch';
import { exportProfileSource, migrateProfileLegacy, readProfileFile,
  stageProfileUri } from './ProfileFiles';
import { mergeProfileItem, ProfileBatchFailure, ProfileBatchResult, ProfileEdit, ProfileItem, ProfileLinkEntry } from './ProfileModels';
import { ProfileLibrarySnapshot, readProfileSnapshot } from './ProfileSnapshot';

export { ProfileEdit, ProfileItem, ProfileBatchResult } from './ProfileModels';
export { SubscriptionUsage } from '../../shared/profiles/Store';
export const ERR_NAME_TAKEN = 'name_taken';
export const ERR_NAME_EMPTY = 'name_empty';
export const ERR_LINK_EXISTS = 'link_exists';
export const ERR_INTERVAL = 'interval_invalid';
export const ERR_IN_USE = 'in_use';

@ObservedV2
export class ProfileStore {
  @Trace items: ProfileItem[] = [];
  @Trace current: string = '';
  @Trace running: string = '';
  @Trace coreReady: boolean = false;
  @Trace offlineWritable: boolean = false;
  @Trace summary: ProfileSummary | undefined = undefined;
  @Trace updatingAll: boolean = false;
  @Trace pending: string = '';
  @Trace loaded: boolean = false;
  @Trace loadError: string = '';
  @Trace applyError: string = '';
  private filesDir: string = '';
  private context?: common.UIAbilityContext;
  private foreground: boolean = true;
  private connectionKnown: boolean = false;
  private legacyMigrated: boolean = false;
  private routeGeneration: number = 0;
  private refreshGeneration: number = 0;
  private summaryGeneration: number = 0;
  private runningQueryGeneration: number = 0;
  private runtimeBootId: string = '';
  private runtimeConfigRevision: number = -1;
  private runtimeRevision: number = -1;
  private retiredRuntimeBoots: Set<string> = new Set<string>();
  private initialized?: Promise<void>;
  private scheduler?: UpdateScheduler;
  private events: ProfileEvents = new ProfileEvents((event: ProfileEvent): void => this.onEvent(event));

  load(context: common.UIAbilityContext): void {
    if (this.initialized !== undefined) { return; }
    this.context = context;
    this.filesDir = context.filesDir;
    this.initialized = this.initialize();
  }

  private async initialize(): Promise<void> {
    try {
      await this.refresh();
      this.scheduler = new UpdateScheduler(this.localEnv(), (outcome: UpdateOutcome): void => {
        if (this.localWritable()) { this.applyOutcome(outcome); }
      });
      if (this.context !== undefined) {
        try { await this.recheckRoute(); } catch (e) { this.applyError = errorString(e as Object); }
        await this.refresh();
      }
      this.syncLifecycle();
    } catch (e) {
      this.loadError = errorString(e as Object);
    } finally {
      this.loaded = true;
      this.syncLifecycle();
    }
  }

  get ready(): boolean { return this.loaded && this.loadError === '' && this.active() !== undefined; }
  active(): ProfileItem | undefined { return this.find(this.coreReady ? this.running : this.current); }
  selectedId(): string { return this.current; }
  find(id: string): ProfileItem | undefined {
    return this.items.find((item: ProfileItem): boolean => item.id === id);
  }

  retryLoad(): void {
    if (!this.loaded) { return; }
    this.scheduler?.stop(true);
    this.loadError = '';
    this.loaded = false;
    this.initialized = this.initialize();
  }

  setCoreReady(coreReady: boolean, offlineWritable: boolean = false): void {
    const writable = !coreReady && offlineWritable;
    const changed = this.coreReady !== coreReady || this.offlineWritable !== writable || !this.connectionKnown;
    this.connectionKnown = true;
    this.coreReady = coreReady;
    this.offlineWritable = writable;
    if (changed) {
      this.routeGeneration++;
      this.runningQueryGeneration++;
      this.scheduler?.stop(true);
      if (!coreReady) { this.running = ''; }
      if (coreReady) { this.refreshRunning(); }
      this.refresh().catch((error: Error): void => { this.loadError = errorString(error); });
    }
    this.syncLifecycle();
  }

  setForeground(foreground: boolean): void {
    const changed = this.foreground !== foreground;
    if (changed) { this.runningQueryGeneration++; }
    this.foreground = foreground;
    if (foreground && this.filesDir !== '') {
      this.refresh().catch((error: Error): void => { this.loadError = errorString(error); });
      if (changed && this.coreReady) { this.refreshRunning(); }
    }
    this.syncLifecycle();
  }

  async addSubscription(rawUrl: string, label: string = ''): Promise<string | undefined> {
    try {
      await this.ensureLoaded();
      const source = rawUrl.trim();
      if (!validSubscriptionUrl(source)) { return 'url_invalid'; }
      if (label.trim().length > 64) { return 'name_long'; }
      const latest = await readListAsync(this.filesDir);
      if (latest.subscriptions.some((sub: SubscriptionRecord): boolean => sub.url === source)) { return ERR_LINK_EXISTS; }
      const profile = newId('p');
      const subscription = newId('s');
      const outcome = await this.remoteOrLocal(
        (): Promise<UpdateOutcome> => addViaVpn(this.filesDir, profile, subscription, source, label.trim()),
        async (): Promise<UpdateOutcome> => {
          const generation = this.routeGeneration;
          return await downloadNewSubscription(this.localEnv(), profile, subscription, source, label.trim(),
            (): boolean => this.localWritable(generation));
        });
      await this.refresh();
      this.notifyChanged();
      return outcome.ok ? await this.activateCurrentIfEmpty() : outcome.error ?? 'network';
    } catch (e) { return errorString(e as Object); }
  }

  async importLocal(): Promise<string | undefined> {
    try {
      await this.ensureLoaded();
      if (this.context === undefined) { return 'io'; }
      const uri = await pickDocumentFile(this.context);
      if (uri === undefined) { return undefined; }
      await this.recheckRoute();
      const generation = this.routeGeneration;
      const env = this.importEnv(generation);
      const profile = newId('p');
      const candidate = await stageProfileUri(this.filesDir, profile, uri);
      const record: ProfileRecord = { id: profile, name: documentFileName(uri) || profile, nameEdited: false,
        subscription: '', type: 'file' };
      const change: ProfileCandidateChange = { create: record };
      try {
        await withProfileTask<void>(this.filesDir, profile, async (): Promise<void> => {
          await commitCandidate(env, profile, candidate, (): boolean => this.businessWritable(generation), change);
        });
      } finally { await removeProfileFile(candidate); }
      await this.refresh();
      return await this.activateCurrentIfEmpty();
    } catch (e) { return errorString(e as Object); }
  }

  async importLinks(text: string): Promise<ProfileBatchResult> {
    await this.ensureLoaded();
    const latest = await readListAsync(this.filesDir);
    const parsed = parseProfileLinks(text, latest.subscriptions.map((sub: SubscriptionRecord): string => sub.url));
    if (parsed.errors.length > 0) {
      return { total: parsed.entries.length, succeeded: 0, skipped: parsed.skipped,
        failures: parsed.errors.map((line: number): ProfileBatchFailure =>
          ({ id: '', name: '', error: 'url_invalid', line: line })) };
    }
    const jobs = parsed.entries.map((entry: ProfileLinkEntry): ProfileBatchJob =>
      ({ id: '', name: hostOf(entry.source), line: entry.line, run: (): Promise<string | undefined> => this.addSubscription(entry.source) }));
    return await runProfileBatch(jobs, parsed.skipped);
  }

  async update(id: string): Promise<string | undefined> {
    const item = this.find(id);
    if (item === undefined || !item.isSubscription) { return 'not_found'; }
    item.updating = true;
    try {
      await this.ensureLoaded();
      const outcome = await this.remoteOrLocal(
        (): Promise<UpdateOutcome> => updateViaVpn(this.filesDir, item.subscription, item.url),
        (): Promise<UpdateOutcome> => this.scheduler !== undefined ? this.scheduler.update(item.subscription, item.url) :
          Promise.reject(new ProfileError('busy')));
      await this.refresh();
      return outcome.ok ? undefined : outcome.error ?? 'network';
    } catch (e) { return errorString(e as Object); }
    finally { item.updating = false; }
  }

  async updateAll(): Promise<ProfileBatchResult> {
    if (this.updatingAll) {
      return { total: 0, succeeded: 0, skipped: 0, failures: [{ id: '', name: '', error: 'busy' }] };
    }
    this.updatingAll = true;
    const jobs = this.items.filter((item: ProfileItem): boolean => item.isSubscription)
      .map((item: ProfileItem): ProfileBatchJob => ({ id: item.id, name: item.name,
        run: (): Promise<string | undefined> => this.update(item.id) }));
    try {
      return await runProfileBatch(jobs, 0);
    } finally { this.updatingAll = false; }
  }

  async select(id: string): Promise<string | undefined> {
    let ownsPending = false;
    try {
      await this.ensureLoaded();
      if (this.pending !== '' || connection.busy) { return 'busy'; }
      if (this.find(id) === undefined) { return 'not_found'; }
      this.pending = id;
      ownsPending = true;
      await this.recheckRoute();
      const generation = this.routeGeneration;
      this.applyError = '';
      this.runningQueryGeneration++;
      await withProfileStorage<void>(this.filesDir, async (): Promise<void> => {
        const latest = await readListAsync(this.filesDir);
        checkProfileCommit((): boolean => this.businessWritable(generation));
        if (findProfile(latest, id) === undefined) { throw new ProfileError('not_found'); }
        latest.current = id;
        await writeList(this.filesDir, latest, (): boolean => this.businessWritable(generation));
      });
      this.current = id;
      checkProfileCommit((): boolean => this.businessWritable(generation));
      if (this.coreReady) {
        await withProfileTask<void>(this.filesDir, id, async (): Promise<void> => {
          checkProfileCommit((): boolean => this.businessWritable(generation));
          await reloadProfile(this.filesDir, id, yamlPath(this.filesDir, id));
        });
        if (generation !== this.routeGeneration || !this.coreReady) { return 'canceled'; }
        await this.refreshRunning();
      }
      await this.refresh();
      return undefined;
    } catch (e) {
      const failure = errorString(e as Object);
      if (ownsPending) { this.applyError = failure; }
      return failure;
    } finally { if (ownsPending) { this.pending = ''; } }
  }

  async edit(id: string, edit: ProfileEdit): Promise<string | undefined> {
    try {
      await this.ensureLoaded();
      await this.recheckRoute();
      const generation = this.routeGeneration;
      if (this.coreReady && edit.content !== undefined) { await this.readRunningStatus(generation); }
      const sourceChanged = await saveProfileEdit(this.importEnv(generation), id, edit,
        (): boolean => this.businessWritable(generation));
      await this.refresh();
      this.notifyChanged();
      if (sourceChanged) {
        const failure = await this.update(id);
        if (failure !== undefined) { return 'metadata_saved'; }
      }
      return undefined;
    } catch (e) {
      const failure = errorString(e as Object);
      if (failure === 'apply_failed') { this.applyError = failure; this.summary = undefined; }
      return failure;
    }
  }

  canRemove(id: string): boolean {
    return this.businessWritable() && this.pending === '' && this.find(id) !== undefined;
  }
  async remove(id: string): Promise<string | undefined> {
    let ownsPending = false;
    try {
      await this.ensureLoaded();
      await this.recheckRoute();
      if (!this.canRemove(id)) { return 'busy'; }
      const latest = await readListAsync(this.filesDir);
      const status = this.coreReady ? await this.readRunningStatus(this.routeGeneration) : undefined;
      if (status !== undefined && (status.profile === id || latest.current === id)) {
        const desired = findProfile(latest, latest.current);
        const next = desired !== undefined && desired.id !== id ? desired :
          latest.profiles.find((record: ProfileRecord): boolean => record.id !== id);
        if (next !== undefined) {
          const failure = await this.select(next.id);
          if (failure !== undefined) { return failure; }
        } else if (this.hasVpnResources(status)) {
          if (this.context === undefined) { return 'io'; }
          await connection.disconnect(this.context);
          if (connection.error !== '') { throw new ProfileError('apply_failed'); }
          await this.recheckRoute();
        }
      }
      if (this.pending !== '') { return 'busy'; }
      this.pending = id;
      ownsPending = true;
      const generation = this.routeGeneration;
      await withProfileTask<void>(this.filesDir, id, async (): Promise<void> => {
        checkProfileCommit((): boolean => this.businessWritable(generation));
        if (this.coreReady) {
          const running = await this.readRunningStatus(generation);
          const beforeClear = await readListAsync(this.filesDir);
          const last = !beforeClear.profiles.some((record: ProfileRecord): boolean => record.id !== id);
          if (running.profile === id || last) {
            if (!last || running.profile !== status?.profile) { throw new ProfileError('conflict'); }
            if (this.hasVpnResources(running)) { throw new ProfileError('apply_failed'); }
            if (running.profile !== '') {
              checkProfileCommit((): boolean => this.businessWritable(generation));
              await reloadProfile(this.filesDir, '', '', running.profile);
              const cleared = await this.readRunningStatus(generation);
              if (cleared.profile !== '' || this.hasVpnResources(cleared)) { throw new ProfileError('apply_failed'); }
            }
          }
        }
        await removeSavedProfile(this.filesDir, id, (): boolean => this.businessWritable(generation));
      });
      await this.refresh();
      this.notifyChanged();
      return undefined;
    } catch (e) {
      const failure = errorString(e as Object);
      this.applyError = failure;
      await this.refresh().catch((): void => {});
      return failure;
    } finally { if (ownsPending) { this.pending = ''; } }
  }

  async reorder(ids: string[]): Promise<string | undefined> {
    try {
      await this.ensureLoaded();
      await this.recheckRoute();
      const generation = this.routeGeneration;
      await saveProfileOrder(this.filesDir, ids, (): boolean => this.businessWritable(generation));
      await this.refresh();
      return undefined;
    }
    catch (e) { return errorString(e as Object); }
  }
  async source(id: string): Promise<string> { await this.ensureLoaded(); return await readSourceText(this.filesDir, id); }
  async pickSource(): Promise<string | undefined> {
    return this.context === undefined ? undefined : await readProfileFile(this.context);
  }
  async validateSource(text: string): Promise<string | undefined> {
    const candidate = candidatePath(this.filesDir, 'draft');
    try {
      await ensureProfilesDir(this.filesDir);
      await writeProfileText(candidate, text);
      const result = await analyze(candidate);
      return result.error === '' ? undefined : result.error;
    } catch (e) { return errorString(e as Object); }
    finally { await removeProfileFile(candidate); }
  }
  async export(id: string): Promise<string | undefined> {
    try {
      if (this.context === undefined) { return 'io'; }
      await exportProfileSource(this.context, id, this.find(id)?.name ?? id);
      return undefined;
    } catch (e) { return errorString(e as Object); }
  }

  async profileSummary(id: string): Promise<ProfileSummary | undefined> {
    await this.ensureLoaded();
    return await readSummary(this.filesDir, id);
  }

  private async ensureLoaded(): Promise<void> {
    await this.initialized;
    if (!this.loaded || this.loadError !== '') { throw new ProfileError(this.loadError || 'busy'); }
  }
  private businessWritable(generation: number = this.routeGeneration): boolean {
    return generation === this.routeGeneration && (this.coreReady || this.offlineWritable) && !connection.busy;
  }
  private localWritable(generation: number = this.routeGeneration): boolean {
    return generation === this.routeGeneration && this.offlineWritable && !this.coreReady && !connection.busy;
  }
  private async recheckRoute(): Promise<void> {
    if (connection.busy) { throw new ProfileError('busy'); }
    if (this.context === undefined) { throw new ProfileError('io'); }
    const generation = this.routeGeneration;
    let coreReady: boolean;
    try { coreReady = await connection.recheck(this.context); }
    catch (e) {
      if (generation === this.routeGeneration) { this.setCoreReady(false, false); }
      throw new ProfileError('host_unknown');
    }
    if (connection.busy) { throw new ProfileError('busy'); }
    if (generation !== this.routeGeneration) {
      if (coreReady ? !this.coreReady : !this.localWritable()) { throw new ProfileError('canceled'); }
    } else { this.setCoreReady(coreReady, !coreReady); }
    if (!this.businessWritable()) { throw new ProfileError('host_unknown'); }
  }
  private localEnv(): UpdateEnv {
    return { filesDir: this.filesDir, downloader: new DirectDownloader(this.filesDir), running: (): string => '',
      eligible: (): boolean => this.localWritable() };
  }
  private importEnv(generation: number): UpdateEnv {
    return { filesDir: this.filesDir, downloader: new DirectDownloader(this.filesDir), running: (): string => this.coreReady ? this.running : '',
      eligible: (): boolean => this.businessWritable(generation),
      reload: async (path: string, profile: string, expectedProfile?: string): Promise<void> => {
        if (!this.coreReady || !this.businessWritable(generation)) { throw new ProfileError('canceled'); }
        await reloadProfile(this.filesDir, profile, path, expectedProfile);
      }, prefetch: (path: string): void => {
        if (this.coreReady && this.businessWritable(generation)) { prefetchProfile(this.filesDir, path).catch((): void => {}); }
      } };
  }
  private async remoteOrLocal(remote: () => Promise<UpdateOutcome>, local: () => Promise<UpdateOutcome>): Promise<UpdateOutcome> {
    await this.recheckRoute();
    if (!this.coreReady) { return await local(); }
    const generation = this.routeGeneration;
    try {
      const outcome = await remote();
      checkProfileCommit((): boolean => this.businessWritable(generation));
      return outcome;
    } catch (e) {
      await this.recheckRoute();
      if (this.coreReady) { throw e as Error; }
      return await local();
    }
  }
  private notifyChanged(): void {
    if (this.coreReady) { notifyListChanged(this.filesDir).catch((): void => {}); }
    else if (this.localWritable()) { this.scheduler?.reschedule(); }
  }
  private syncLifecycle(): void {
    if (this.foreground && this.coreReady) { this.events.start(this.filesDir); } else { this.events.stop(); }
    if (this.localWritable() && this.foreground && this.loaded) { this.scheduler?.start(); }
    else { this.scheduler?.stop(true); }
  }
  private applyOutcome(outcome: UpdateOutcome): void {
    if (outcome.error === 'apply_failed') { this.applyError = 'apply_failed'; }
    this.refresh().catch((error: Error): void => { this.loadError = errorString(error); });
  }
  private onEvent(event: ProfileEvent): void {
    if (!this.coreReady || !this.foreground || connection.busy) { return; }
    const status = event.status;
    if (event.type === 'runtime' && status !== undefined) {
      if (this.retiredRuntimeBoots.has(status.bootId)) { return; }
      if (status.bootId === this.runtimeBootId && connection.bootId !== '' &&
        connection.bootId !== status.bootId && !this.retiredRuntimeBoots.has(connection.bootId)) {
        this.refreshRunning();
      } else if (this.applyRunningStatus(status)) { this.runningQueryGeneration++; }
    } else if (event.type === 'reloaded') { this.refreshRunning(); }
    this.refresh().catch((error: Error): void => { this.loadError = errorString(error); });
  }

  private runningQueryCurrent(query: number, route: number): boolean {
    return query === this.runningQueryGeneration && route === this.routeGeneration &&
      this.coreReady && this.foreground && !connection.busy;
  }

  private async refreshRunning(): Promise<void> {
    if (!this.coreReady || !this.foreground || connection.busy || this.filesDir === '') { return; }
    const query = ++this.runningQueryGeneration;
    const route = this.routeGeneration;
    const boot = connection.bootId;
    try {
      const status = await getRuntimeStatus(this.filesDir);
      if (!this.runningQueryCurrent(query, route)) { return; }
      if (boot !== connection.bootId) { await this.refreshRunning(); return; }
      this.applyRunningStatus(status);
    } catch (error) {
      if (!this.runningQueryCurrent(query, route)) { return; }
      if (boot !== connection.bootId) { await this.refreshRunning(); return; }
      this.applyError = errorString(error as Object);
    }
  }

  private async readRunningStatus(generation: number): Promise<RuntimeStatus> {
    const boot = connection.bootId;
    this.runningQueryGeneration++;
    const status = await getRuntimeStatus(this.filesDir);
    checkProfileCommit((): boolean => this.coreReady && this.businessWritable(generation));
    if (boot !== connection.bootId || (connection.bootId !== '' && status.bootId !== connection.bootId)) {
      throw new ProfileError('canceled');
    }
    if (!this.acceptsRunningStatus(status)) { throw new ProfileError('conflict'); }
    this.applyRunningStatus(status);
    return status;
  }

  private async activateCurrentIfEmpty(): Promise<string | undefined> {
    if (!this.coreReady) { return undefined; }
    const generation = this.routeGeneration;
    let ownsPending = false;
    try {
      this.applyError = '';
      for (;;) {
        checkProfileCommit((): boolean => this.coreReady && this.businessWritable(generation));
        const latest = await readListAsync(this.filesDir);
        const id = latest.current;
        if (id === '') { return undefined; }
        let changed = false;
        await withProfileTask<void>(this.filesDir, id, async (): Promise<void> => {
          const status = await this.readRunningStatus(generation);
          if (!status.running) { throw new ProfileError('apply_failed'); }
          if (status.profile !== '') { return; }
          // 提交锁已经释放；任务锁后的最新选择决定首次加载，不能回写旧的 current。
          const current = await readListAsync(this.filesDir);
          checkProfileCommit((): boolean => this.businessWritable(generation));
          if (current.current !== id) { changed = true; return; }
          if (findProfile(current, id) === undefined) { throw new ProfileError('not_found'); }
          if (this.pending !== '') { throw new ProfileError('busy'); }
          this.pending = id;
          ownsPending = true;
          await reloadProfile(this.filesDir, id, yamlPath(this.filesDir, id), '');
          const applied = await this.readRunningStatus(generation);
          if (!applied.running || applied.profile === '') { throw new ProfileError('apply_failed'); }
        });
        if (!changed) { await this.refresh(); return undefined; }
      }
    } catch (e) {
      const failure = errorString(e as Object);
      this.applyError = failure;
      return failure;
    } finally { if (ownsPending) { this.pending = ''; } }
  }

  private hasVpnResources(status: RuntimeStatus): boolean {
    return status.vpnCreated || status.tunAttached || status.listenersOpen || status.intent === 'started' ||
      status.forward === 'preparing' || status.forward === 'running';
  }

  private acceptsRunningStatus(status: RuntimeStatus): boolean {
    if (typeof status.bootId !== 'string' || status.bootId === '' || typeof status.profile !== 'string' ||
      typeof status.running !== 'boolean' || !Number.isSafeInteger(status.configRevision) || status.configRevision < 0 ||
      !Number.isSafeInteger(status.revision) || status.revision < 0 || this.retiredRuntimeBoots.has(status.bootId)) {
      return false;
    }
    return status.bootId !== this.runtimeBootId ||
      (status.configRevision >= this.runtimeConfigRevision && status.revision >= this.runtimeRevision);
  }

  private applyRunningStatus(status: RuntimeStatus): boolean {
    if (!this.acceptsRunningStatus(status)) { return false; }
    const sameBoot = status.bootId === this.runtimeBootId;
    const profile = status.running ? status.profile : '';
    const changed = !sameBoot || status.configRevision !== this.runtimeConfigRevision || profile !== this.running;
    const advanced = status.revision !== this.runtimeRevision;
    if (!sameBoot && this.runtimeBootId !== '') { this.retiredRuntimeBoots.add(this.runtimeBootId); }
    this.runtimeBootId = status.bootId;
    this.runtimeConfigRevision = status.configRevision;
    this.runtimeRevision = status.revision;
    this.running = profile;
    if (changed) {
      if (profile === this.current && this.applyError !== 'apply_failed') { this.applyError = ''; }
      this.refreshSummary();
    }
    return changed || advanced;
  }
  private async refresh(): Promise<void> {
    if (this.filesDir === '') { return; }
    const generation = ++this.refreshGeneration;
    if (!this.legacyMigrated && this.localWritable() && this.context !== undefined) {
      const route = this.routeGeneration;
      try {
        await migrateProfileLegacy(this.context, (): boolean => this.localWritable(route));
        if (this.localWritable(route)) { this.legacyMigrated = true; }
      } catch (e) {
        if (errorString(e as Object) !== 'canceled') { throw e as Error; }
      }
    }
    let snapshot: ProfileLibrarySnapshot;
    try { snapshot = await readProfileSnapshot(this.filesDir); }
    catch (e) { if (generation !== this.refreshGeneration) { return; } throw e as Error; }
    if (generation !== this.refreshGeneration) { return; }
    this.items = snapshot.items.map((fresh: ProfileItem): ProfileItem => mergeProfileItem(this.find(fresh.id), fresh));
    this.current = snapshot.list.current;
    if (this.coreReady && this.active()?.state.error === 'apply_failed') { this.applyError = 'apply_failed'; }
    this.loadError = '';
    this.refreshSummary();
  }
  private refreshSummary(): void {
    const generation = ++this.summaryGeneration;
    const id = this.coreReady ? this.running : this.current;
    if (id === '' || (this.coreReady && this.applyError === 'apply_failed')) { this.summary = undefined; return; }
    readSummary(this.filesDir, id).then((summary: ProfileSummary | undefined): void => {
      if (generation === this.summaryGeneration && id === (this.coreReady ? this.running : this.current)) { this.summary = summary; }
    }).catch((error: Error): void => {
      if (generation === this.summaryGeneration) { this.loadError = errorString(error); }
    });
  }
}
