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
import { ProfileBatchJob, runProfileBatch } from './ProfileBatch';
import { exportProfileSource, migrateProfileLegacy, pickProfileFile, profileFileName, readProfileFile,
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
  @Trace connected: boolean = false;
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
      if (!this.connectionKnown && this.context !== undefined) {
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
  active(): ProfileItem | undefined { return this.find(this.connected ? this.running : this.current); }
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

  setConnected(connected: boolean, offlineWritable: boolean = false): void {
    const writable = !connected && offlineWritable;
    const changed = this.connected !== connected || this.offlineWritable !== writable || !this.connectionKnown;
    this.connectionKnown = true;
    this.connected = connected;
    this.offlineWritable = writable;
    if (changed) {
      this.routeGeneration++;
      this.runningQueryGeneration++;
      this.scheduler?.stop(true);
      if (!connected) { this.running = ''; }
      if (connected) { this.refreshRunning(); }
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
      if (changed && this.connected) { this.refreshRunning(); }
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
      return outcome.ok ? undefined : outcome.error ?? 'network';
    } catch (e) { return errorString(e as Object); }
  }

  async importLocal(): Promise<string | undefined> {
    try {
      await this.ensureLoaded();
      if (this.context === undefined) { return 'io'; }
      const uri = await pickProfileFile(this.context);
      if (uri === undefined) { return undefined; }
      await this.recheckRoute();
      const generation = this.routeGeneration;
      const env = this.importEnv(generation);
      const profile = newId('p');
      const candidate = await stageProfileUri(this.filesDir, profile, uri);
      const record: ProfileRecord = { id: profile, name: profileFileName(uri) || profile, nameEdited: false,
        subscription: '', type: 'file' };
      const change: ProfileCandidateChange = { create: record };
      try {
        await withProfileTask<void>(this.filesDir, profile, async (): Promise<void> => {
          await commitCandidate(env, profile, candidate, (): boolean => this.businessWritable(generation), change);
        });
      } finally { await removeProfileFile(candidate); }
      await this.refresh();
      return undefined;
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
      if (this.connected) {
        await withProfileTask<void>(this.filesDir, id, async (): Promise<void> => {
          checkProfileCommit((): boolean => this.businessWritable(generation));
          await reloadProfile(this.filesDir, id, yamlPath(this.filesDir, id));
        });
        if (generation !== this.routeGeneration || !this.connected) { return 'canceled'; }
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
    try {
      await this.ensureLoaded();
      await this.recheckRoute();
      if (!this.canRemove(id)) { return 'busy'; }
      if (this.connected && (this.running === id || this.current === id)) {
        const desired = this.find(this.current);
        const next = desired !== undefined && desired.id !== id ? desired :
          this.items.find((item: ProfileItem): boolean => item.id !== id);
        if (next !== undefined) {
          const failure = await this.select(next.id);
          if (failure !== undefined) { return failure; }
        } else if (this.context !== undefined) {
          await connection.disconnect(this.context);
          if (connection.error !== '') { return 'apply_failed'; }
          await this.recheckRoute();
          if (!this.localWritable()) { return 'apply_failed'; }
        } else { return 'io'; }
      }
      const generation = this.routeGeneration;
      await removeSavedProfile(this.filesDir, id, (): boolean => this.businessWritable(generation));
      await this.refresh();
      this.notifyChanged();
      return undefined;
    } catch (e) {
      const failure = errorString(e as Object);
      await this.refresh().catch((): void => {});
      return failure;
    }
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
    return generation === this.routeGeneration && (this.connected || this.offlineWritable) && !connection.busy;
  }
  private localWritable(generation: number = this.routeGeneration): boolean {
    return generation === this.routeGeneration && this.offlineWritable && !this.connected && !connection.busy;
  }
  private async recheckRoute(): Promise<void> {
    if (connection.busy) { throw new ProfileError('busy'); }
    if (this.context === undefined) { throw new ProfileError('io'); }
    const generation = this.routeGeneration;
    let connected: boolean;
    try { connected = await connection.recheck(this.context); }
    catch (e) {
      if (generation === this.routeGeneration) { this.setConnected(false, false); }
      throw new ProfileError('host_unknown');
    }
    if (connection.busy) { throw new ProfileError('busy'); }
    if (generation !== this.routeGeneration) {
      if (connected ? !this.connected : !this.localWritable()) { throw new ProfileError('canceled'); }
    } else { this.setConnected(connected, !connected); }
    if (!this.businessWritable()) { throw new ProfileError('host_unknown'); }
  }
  private localEnv(): UpdateEnv {
    return { filesDir: this.filesDir, downloader: new DirectDownloader(), running: (): string => '',
      eligible: (): boolean => this.localWritable() };
  }
  private importEnv(generation: number): UpdateEnv {
    return { filesDir: this.filesDir, downloader: new DirectDownloader(), running: (): string => this.connected ? this.running : '',
      eligible: (): boolean => this.businessWritable(generation),
      reload: async (path: string, profile: string, expectedProfile?: string): Promise<void> => {
        if (!this.connected || !this.businessWritable(generation)) { throw new ProfileError('canceled'); }
        await reloadProfile(this.filesDir, profile, path, expectedProfile);
      }, prefetch: (path: string): void => {
        if (this.connected && this.businessWritable(generation)) { prefetchProfile(this.filesDir, path).catch((): void => {}); }
      } };
  }
  private async remoteOrLocal(remote: () => Promise<UpdateOutcome>, local: () => Promise<UpdateOutcome>): Promise<UpdateOutcome> {
    await this.recheckRoute();
    if (!this.connected) { return await local(); }
    const generation = this.routeGeneration;
    try {
      const outcome = await remote();
      checkProfileCommit((): boolean => this.businessWritable(generation));
      return outcome;
    } catch (e) {
      await this.recheckRoute();
      if (this.connected) { throw e as Error; }
      return await local();
    }
  }
  private notifyChanged(): void {
    if (this.connected) { notifyListChanged(this.filesDir).catch((): void => {}); }
    else if (this.localWritable()) { this.scheduler?.reschedule(); }
  }
  private syncLifecycle(): void {
    if (this.foreground && this.connected) { this.events.start(this.filesDir); } else { this.events.stop(); }
    if (this.localWritable() && this.foreground && this.loaded) { this.scheduler?.start(); }
    else { this.scheduler?.stop(true); }
  }
  private applyOutcome(outcome: UpdateOutcome): void {
    if (outcome.error === 'apply_failed') { this.applyError = 'apply_failed'; }
    this.refresh().catch((error: Error): void => { this.loadError = errorString(error); });
  }
  private onEvent(event: ProfileEvent): void {
    if (!this.connected || !this.foreground || connection.busy) { return; }
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
      this.connected && this.foreground && !connection.busy;
  }

  private async refreshRunning(): Promise<void> {
    if (!this.connected || !this.foreground || connection.busy || this.filesDir === '') { return; }
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

  private applyRunningStatus(status: RuntimeStatus): boolean {
    if (typeof status.bootId !== 'string' || status.bootId === '' || typeof status.profile !== 'string' ||
      typeof status.running !== 'boolean' || !Number.isSafeInteger(status.configRevision) || status.configRevision < 0 ||
      !Number.isSafeInteger(status.revision) || status.revision < 0 || this.retiredRuntimeBoots.has(status.bootId)) {
      return false;
    }
    const sameBoot = status.bootId === this.runtimeBootId;
    if (sameBoot && (status.configRevision < this.runtimeConfigRevision || status.revision < this.runtimeRevision)) { return false; }
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
    if (this.connected && this.active()?.state.error === 'apply_failed') { this.applyError = 'apply_failed'; }
    this.loadError = '';
    this.refreshSummary();
  }
  private refreshSummary(): void {
    const generation = ++this.summaryGeneration;
    const id = this.connected ? this.running : this.current;
    if (id === '' || (this.connected && this.applyError === 'apply_failed')) { this.summary = undefined; return; }
    readSummary(this.filesDir, id).then((summary: ProfileSummary | undefined): void => {
      if (generation === this.summaryGeneration && id === (this.connected ? this.running : this.current)) { this.summary = summary; }
    }).catch((error: Error): void => {
      if (generation === this.summaryGeneration) { this.loadError = errorString(error); }
    });
  }
}
