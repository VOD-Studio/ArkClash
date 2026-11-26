import { common } from '@kit.AbilityKit';
import { ControllerSocket } from '../../client/ControllerSocket';
import { applyGeoSettings, geoResourceError, getGeoSnapshot, parseGeoEvent,
  updateGeoResources } from '../../client/GeoResources';
import { defaultGeoSettings, flushGeoSettings, GEO_RESOURCE_IDS, GeoResourceId, GeoResourceOutcome,
  GeoResourcePhase, GeoResourceStatus, GeoSettings, GeoSnapshot, readGeoFileInfos, readGeoSettings,
  resetGeoSettings, saveGeoSettings } from '../../shared/GeoResources';

@ObservedV2
export class GeoResourceItem implements GeoResourceStatus {
  @Trace id: GeoResourceId;
  @Trace fileName: string = '';
  @Trace exists: boolean = false;
  @Trace size: number = 0;
  @Trace modifiedAt: number = 0;
  @Trace phase: GeoResourcePhase = 'idle';
  @Trace operationId: string = '';
  @Trace outcome: GeoResourceOutcome = 'none';
  @Trace error: string = '';

  constructor(id: GeoResourceId) { this.id = id; }
}

export interface GeoResourceNotice {
  kind: 'saved' | 'pending' | 'single' | 'batch' | 'error';
  items: GeoResourceStatus[];
  error: string;
}

interface GeoBatchEntry {
  id: GeoResourceId;
  operationId: string;
  result?: GeoResourceStatus;
}

interface GeoPageBatch {
  entries: GeoBatchEntry[];
}

function copyGeoStatus(item: GeoResourceStatus): GeoResourceStatus {
  return { id: item.id, fileName: item.fileName, exists: item.exists, size: item.size,
    modifiedAt: item.modifiedAt, phase: item.phase, operationId: item.operationId,
    outcome: item.outcome, error: item.error };
}

function copyGeoSettings(settings: GeoSettings, revision: string): GeoSettings {
  return { version: 1, revision: revision, autoUpdate: settings.autoUpdate, intervalHours: settings.intervalHours,
    urls: { mmdb: settings.urls.mmdb, asn: settings.urls.asn, geoip: settings.urls.geoip, geosite: settings.urls.geosite } };
}

@ObservedV2
export class ResourcesStore {
  @Trace items: GeoResourceItem[] = GEO_RESOURCE_IDS.map((id: GeoResourceId): GeoResourceItem => new GeoResourceItem(id));
  @Trace settings: GeoSettings = defaultGeoSettings();
  @Trace loaded: boolean = false;
  @Trace saving: boolean = false;
  @Trace settingsError: string = '';
  @Trace error: string = '';
  @Trace pendingApply: boolean = false;
  @Trace now: number = Date.now();
  @Trace noticeSerial: number = 0;
  @Trace notice?: GeoResourceNotice;
  @Trace private visible: boolean = false;
  @Trace private ready: boolean = false;
  @Trace private bootId: string = '';
  @Trace private snapshotRevision: number = -1;
  @Trace private appliedRevision: string = '';
  private filesDir: string = '';
  private generation: number = 0;
  private readVersion: number = 0;
  private localGeneration: number = -1;
  private loadingGeneration: number = -1;
  private loadingReadVersion: number = -1;
  private loading?: Promise<void>;
  private onlineGeneration: number = -1;
  private socket?: ControllerSocket;
  private clock: number = -1;
  private attemptedGeneration: number = -1;
  private batches: GeoPageBatch[] = [];
  private admissions: number = 0;
  private terminalBeforeAdmission: Map<string, GeoResourceStatus> = new Map<string, GeoResourceStatus>();
  private notices: GeoResourceNotice[] = [];

  get canSync(): boolean {
    return this.visible && this.ready && this.bootId !== '' && this.loaded && this.localGeneration === this.generation &&
      this.settingsError === '' && !this.saving && this.snapshotRevision >= 0 && !this.pendingApply &&
      this.appliedRevision === this.settings.revision;
  }

  load(context: common.UIAbilityContext): Promise<void> {
    this.filesDir = context.filesDir;
    return this.refresh();
  }

  setVisible(visible: boolean): void {
    if (this.visible === visible) { return; }
    this.visible = visible;
    this.invalidate();
    if (visible) {
      this.now = Date.now();
      this.clock = setInterval((): void => { this.now = Date.now(); }, 60000);
      this.refreshQuietly();
    } else if (this.clock !== -1) {
      clearInterval(this.clock);
      this.clock = -1;
    }
  }

  setConnection(ready: boolean, bootId: string): void {
    if (this.ready === ready && this.bootId === bootId) { return; }
    this.ready = ready;
    this.bootId = bootId;
    this.invalidate();
    if (this.visible) { this.refreshQuietly(); }
  }

  private invalidate(): void {
    ++this.generation;
    this.socket?.stop();
    this.socket = undefined;
    this.snapshotRevision = -1;
    this.appliedRevision = '';
    this.pendingApply = false;
    this.batches = [];
    this.admissions = 0;
    this.terminalBeforeAdmission.clear();
    this.notices = [];
    this.notice = undefined;
    for (const item of this.items) {
      item.phase = 'idle';
      item.operationId = '';
      item.outcome = 'none';
    }
  }

  private current(generation: number): boolean { return generation === this.generation; }

  private refreshQuietly(): void {
    this.refresh().catch((): void => {});
  }

  private refresh(): Promise<void> {
    if (this.filesDir === '' || this.localGeneration === this.generation) { return Promise.resolve(); }
    if (this.loadingGeneration === this.generation && this.loadingReadVersion === this.readVersion &&
      this.loading !== undefined) { return this.loading; }
    this.loadingGeneration = this.generation;
    this.loadingReadVersion = this.readVersion;
    this.loading = this.readLocal(this.generation, this.readVersion);
    return this.loading;
  }

  private async readLocal(generation: number, readVersion: number): Promise<void> {
    // 最后一次保存失败仍可读取旧文件；屏障只保证本次读取不会越过尚未结束的提交。
    try { await flushGeoSettings(); } catch (_error) {}
    let settings: GeoSettings | undefined;
    let settingsError: string = '';
    let infos: GeoResourceStatus[] = [];
    let fileError: string = '';
    try { settings = await readGeoSettings(this.filesDir); }
    catch (error) { settingsError = geoResourceError(error as Object); }
    try { infos = await readGeoFileInfos(this.filesDir); }
    catch (error) { fileError = geoResourceError(error as Object); }
    if (!this.current(generation) || readVersion !== this.readVersion) { return; }
    if (settings !== undefined) { this.settings = settings; }
    this.settingsError = settingsError;
    this.error = fileError;
    for (const info of infos) { this.mergeItem(info); }
    this.loaded = true;
    this.localGeneration = generation;
    await this.startOnline(generation);
  }

  private async startOnline(generation: number): Promise<void> {
    if (!this.current(generation) || !this.visible || !this.ready || this.bootId === '' ||
      this.localGeneration !== generation || this.onlineGeneration === generation) { return; }
    this.onlineGeneration = generation;
    const socket = new ControllerSocket('/arkclash/geo/events', (text: string): void => {
      if (!this.current(generation) || !this.visible) { return; }
      try {
        this.accept(parseGeoEvent(text));
        this.applyOnRestore(generation).catch((): void => {});
      } catch (_error) { this.error = 'geo_invalid_data'; }
    });
    this.socket = socket;
    socket.start(this.filesDir);
    try {
      const snapshot = await getGeoSnapshot(this.filesDir);
      if (!this.current(generation)) { return; }
      this.accept(snapshot);
      await this.applyOnRestore(generation);
    } catch (error) {
      if (this.current(generation) && this.snapshotRevision < 0) { this.error = geoResourceError(error as Object); }
      await this.applyOnRestore(generation);
    }
  }

  private async applyOnRestore(generation: number): Promise<void> {
    if (!this.current(generation) || this.snapshotRevision < 0 || this.settingsError !== '' || this.saving ||
      this.appliedRevision === this.settings.revision || this.attemptedGeneration === generation) { return; }
    this.attemptedGeneration = generation;
    await this.applySaved(generation);
  }

  private accept(snapshot: GeoSnapshot): void {
    if (snapshot.bootId !== this.bootId || snapshot.revision <= this.snapshotRevision) { return; }
    this.snapshotRevision = snapshot.revision;
    this.appliedRevision = snapshot.settingsRevision;
    this.pendingApply = this.settingsError === '' && this.appliedRevision !== this.settings.revision;
    this.error = '';
    for (const status of snapshot.items) {
      if (status.phase === 'idle' && status.operationId !== '' && status.outcome !== 'none') {
        const terminal = copyGeoStatus(status);
        if (this.admissions > 0) { this.terminalBeforeAdmission.set(status.operationId, terminal); }
        for (const batch of this.batches) {
          for (const entry of batch.entries) {
            if (entry.id === status.id && entry.operationId === status.operationId && entry.result === undefined) {
              entry.result = terminal;
            }
          }
        }
      }
      this.mergeItem(status);
    }
    this.finishBatches();
  }

  private mergeItem(status: GeoResourceStatus): void {
    const item = this.items.find((candidate: GeoResourceItem): boolean => candidate.id === status.id);
    if (item === undefined) { return; }
    if (item.fileName !== status.fileName) { item.fileName = status.fileName; }
    if (item.exists !== status.exists) { item.exists = status.exists; }
    if (item.size !== status.size) { item.size = status.size; }
    if (item.modifiedAt !== status.modifiedAt) { item.modifiedAt = status.modifiedAt; }
    if (item.phase !== status.phase) { item.phase = status.phase; }
    if (item.operationId !== status.operationId) { item.operationId = status.operationId; }
    if (item.outcome !== status.outcome) { item.outcome = status.outcome; }
    if (item.error !== status.error) { item.error = status.error; }
  }

  private async applySaved(generation: number): Promise<void> {
    if (!this.visible || !this.ready || this.snapshotRevision < 0) {
      this.pendingApply = this.ready;
      return;
    }
    this.pendingApply = true;
    this.attemptedGeneration = generation;
    try {
      const snapshot = await applyGeoSettings(this.filesDir, this.bootId, this.settings.revision);
      if (this.current(generation)) { this.accept(snapshot); }
    } catch (error) {
      if (this.current(generation)) {
        this.pendingApply = this.appliedRevision !== this.settings.revision;
        if (this.pendingApply) { this.error = geoResourceError(error as Object); }
      }
    }
  }

  saveUrl(id: GeoResourceId, source: string, expectedRevision?: string): Promise<void> {
    const draft = copyGeoSettings(this.settings, expectedRevision ?? this.settings.revision);
    switch (id) {
      case 'mmdb': draft.urls.mmdb = source; break;
      case 'asn': draft.urls.asn = source; break;
      case 'geoip': draft.urls.geoip = source; break;
      case 'geosite': draft.urls.geosite = source; break;
    }
    return this.save(draft, false);
  }

  saveAutoUpdate(enabled: boolean): Promise<void> {
    const draft = copyGeoSettings(this.settings, this.settings.revision);
    draft.autoUpdate = enabled;
    return this.save(draft, false);
  }

  saveInterval(hours: number, expectedRevision?: string): Promise<void> {
    const draft = copyGeoSettings(this.settings, expectedRevision ?? this.settings.revision);
    draft.intervalHours = hours;
    return this.save(draft, false);
  }

  resetSettings(): Promise<void> { return this.save(defaultGeoSettings(), true); }

  private async save(draft: GeoSettings, reset: boolean): Promise<void> {
    if (this.saving || this.filesDir === '' || !this.loaded) { throw new Error('geo_invalid_settings'); }
    this.saving = true;
    ++this.readVersion;
    const generation = this.generation;
    try {
      const saved = reset ? await resetGeoSettings(this.filesDir) : await saveGeoSettings(this.filesDir, draft);
      if (!this.current(generation)) { return; }
      this.settings = saved;
      this.settingsError = '';
      this.error = '';
      await this.applySaved(generation);
      if (this.current(generation) && this.visible) {
        const notice: GeoResourceNotice = { kind: this.pendingApply ? 'pending' : 'saved', items: [], error: '' };
        this.emitNotice(notice);
      }
    } catch (error) {
      if (!this.current(generation)) { return; }
      const code = geoResourceError(error as Object);
      if (code === 'geo_settings_conflict') {
        try {
          const committed = await readGeoSettings(this.filesDir);
          if (this.current(generation)) {
            this.settings = committed;
            this.settingsError = '';
            this.pendingApply = this.ready && this.appliedRevision !== committed.revision;
          }
        } catch (readError) {
          if (this.current(generation)) { this.settingsError = geoResourceError(readError as Object); }
        }
      }
      if (this.current(generation)) { throw new Error(code); }
    } finally {
      this.saving = false;
      if (this.localGeneration !== this.generation) {
        this.refreshQuietly();
      } else {
        this.applyOnRestore(this.generation).catch((): void => {});
      }
    }
  }

  async sync(ids: GeoResourceId[]): Promise<void> {
    if (!this.canSync) { throw new Error('geo_stale_boot'); }
    const requested: GeoResourceId[] = [];
    for (const id of ids) {
      if (!GEO_RESOURCE_IDS.includes(id)) { throw new Error('geo_invalid_data'); }
      if (!requested.includes(id)) { requested.push(id); }
    }
    if (requested.length === 0) { throw new Error('geo_invalid_data'); }
    const generation = this.generation;
    ++this.admissions;
    try {
      const snapshot = await updateGeoResources(this.filesDir, this.bootId, requested);
      if (!this.current(generation)) { return; }
      if (snapshot.bootId !== this.bootId) { throw new Error('geo_stale_boot'); }
      this.accept(snapshot);
      const entries: GeoBatchEntry[] = [];
      for (const id of requested) {
        const status = snapshot.items.find((item: GeoResourceStatus): boolean => item.id === id);
        if (status === undefined || status.operationId === '') { throw new Error('geo_invalid_data'); }
        let result = this.terminalBeforeAdmission.get(status.operationId);
        if (result === undefined && status.phase === 'idle' && status.outcome !== 'none') {
          result = copyGeoStatus(status);
        }
        const entry: GeoBatchEntry = { id: id, operationId: status.operationId, result: result };
        entries.push(entry);
      }
      const batch: GeoPageBatch = { entries: entries };
      this.batches.push(batch);
      this.finishBatches();
    } catch (error) {
      if (this.current(generation)) { throw new Error(geoResourceError(error as Object)); }
    } finally {
      if (this.current(generation)) {
        --this.admissions;
        if (this.admissions === 0) { this.terminalBeforeAdmission.clear(); }
      }
    }
  }

  private finishBatches(): void {
    const remaining: GeoPageBatch[] = [];
    for (const batch of this.batches) {
      const results: GeoResourceStatus[] = [];
      for (const entry of batch.entries) {
        if (entry.result !== undefined) { results.push(entry.result); }
      }
      if (results.length !== batch.entries.length) { remaining.push(batch); continue; }
      const notice: GeoResourceNotice = { kind: results.length === 1 ? 'single' : 'batch', items: results, error: '' };
      this.emitNotice(notice);
    }
    this.batches = remaining;
  }

  private emitNotice(notice: GeoResourceNotice): void {
    if (!this.visible) { return; }
    if (this.notice !== undefined) { this.notices.push(notice); return; }
    this.notice = notice;
    ++this.noticeSerial;
  }

  clearNotice(): void {
    this.notice = this.notices.shift();
    if (this.notice !== undefined) { ++this.noticeSerial; }
  }
}

export const resourcesStore: ResourcesStore = new ResourcesStore();
