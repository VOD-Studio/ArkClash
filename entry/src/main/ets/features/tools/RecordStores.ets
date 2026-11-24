import { common } from '@kit.AbilityKit';
import { ControllerSocket, ControllerSocketState } from '../../client/ControllerSocket';
import {
  DiagnosticRuntime, DiagnosticConnection, DiagnosticTraffic, DiagnosticDnsRecord,
  DiagnosticConnectionsFrame, DiagnosticDnsFrame, createConnectionsStream, createDnsStream,
  closeDiagnosticConnections, clearDiagnosticDnsCache, diagnosticError
} from '../../client/Diagnostics';
import { KeyedListSource } from '../../components/KeyedListSource';
import {
  RequestFeed, RecordGrouping, RecordView, RecordFacets, RecordSort, ConnectionRecordView,
  RecordGroup, TrackerSpeedRanker, filterConnections, filterDns, groupConnections,
  sortConnections, sortDns, connectionFacetOptions, dnsFacetOptions
} from './RecordLogic';
import {
  RecordPreferenceSnapshot, loadRecordPreferences, saveRecordFeed, saveRecordGrouping,
  saveRecordColumnWidths
} from './RecordPreferences';

@ObservedV2
export class ConnectionListRow {
  readonly key: string;
  @Trace group: string = '';
  @Trace groupCount: number = 0;
  @Trace expanded: boolean = true;
  @Trace record?: ConnectionRecordView;

  constructor(key: string) { this.key = key; }
}

export interface DnsListRow {
  key: string;
  record: DiagnosticDnsRecord;
}

interface RecordHistoryItem {
  id: string;
}

// canonical 按内核顺序保存；暂停时保留独立、有界的滚动窗口。
class RecordHistory<T extends RecordHistoryItem> {
  private canonical: Map<string, T> = new Map<string, T>();
  private paused: T[] = [];
  private pausedIndices: Map<string, number> = new Map<string, number>();
  private limit: number;
  private pausedLimit: number;
  following: boolean = true;
  anchor: string = '';

  constructor(limit: number, pausedLimit: number) {
    this.limit = limit;
    this.pausedLimit = pausedLimit;
  }

  clear(): void {
    this.canonical.clear();
    this.paused = [];
    this.pausedIndices.clear();
    this.following = true;
    this.anchor = '';
  }

  values(): T[] {
    return this.following ? Array.from<T>(this.canonical.values()) : this.paused;
  }

  get count(): number { return this.following ? this.canonical.size : this.paused.length; }

  get(id: string): T | undefined {
    const index = this.pausedIndices.get(id);
    return this.canonical.get(id) ?? (index === undefined ? undefined : this.paused[index]);
  }

  append(records: T[]): void {
    for (const record of records) { this.canonical.set(record.id, record); }
    if (this.canonical.size > this.limit) {
      for (const id of this.canonical.keys()) {
        this.canonical.delete(id);
        if (this.canonical.size === this.limit) { break; }
      }
    }
    this.mergePaused(records);
  }

  update(record: T): void {
    if (this.canonical.has(record.id)) { this.canonical.set(record.id, record); }
    const index = this.pausedIndices.get(record.id);
    if (index !== undefined) { this.paused[index] = record; }
  }

  replace(records: T[], newSession: boolean): void {
    this.canonical.clear();
    // 同一 boot/revision 的新流也可能来自新 collector，不能携带旧暂停记录。
    if (newSession && !this.following) {
      this.paused = [];
      this.pausedIndices.clear();
    }
    this.append(records);
  }

  setFollowing(following: boolean): void {
    if (following === this.following) { return; }
    if (!following) {
      this.paused = Array.from<T>(this.canonical.values());
      this.reindexPaused();
    } else {
      this.paused = [];
      this.pausedIndices.clear();
      this.anchor = '';
    }
    this.following = following;
  }

  private mergePaused(records: T[]): void {
    if (this.following) { return; }
    for (const record of records) {
      const index = this.pausedIndices.get(record.id);
      if (index === undefined) {
        this.pausedIndices.set(record.id, this.paused.length);
        this.paused.push(record);
      } else {
        this.paused[index] = record;
      }
    }
    if (this.paused.length > this.pausedLimit) {
      this.paused.splice(0, this.paused.length - this.pausedLimit);
      this.reindexPaused();
    }
    if (this.anchor !== '' && !this.pausedIndices.has(this.anchor)) {
      this.anchor = this.paused.length > 0 ? this.paused[0].id : '';
    }
  }

  private reindexPaused(): void {
    this.pausedIndices.clear();
    for (let index = 0; index < this.paused.length; index++) {
      this.pausedIndices.set(this.paused[index].id, index);
    }
  }
}

// 没有 UI 计时器；重连完全交给 ControllerSocket 的有界策略。
class RecordStreamSession {
  runtime: DiagnosticRuntime = { bootId: '', configRevision: 0 };
  visible: boolean = false;
  ready: boolean = false;
  fresh: boolean = false;
  state: ControllerSocketState = 'closed';
  socket?: ControllerSocket;
  generation: number = 0;
  actionEpoch: number = 0;
  sessionId: string = '';
  sequence: number = 0;
  filesDir: string = '';

  get canAct(): boolean {
    return this.visible && this.ready && this.fresh && this.state === 'open' && this.filesDir !== '';
  }

  get shouldStart(): boolean {
    return this.visible && this.ready && this.filesDir !== '' && this.runtime.bootId !== '' &&
      this.runtime.configRevision > 0;
  }

  setRuntime(ready: boolean, bootId: string, configRevision: number): boolean {
    const valid = bootId !== '' && Number.isSafeInteger(configRevision) && configRevision > 0;
    const nextBoot = valid ? bootId : '';
    const nextRevision = valid ? configRevision : 0;
    const changed = nextBoot !== this.runtime.bootId || nextRevision !== this.runtime.configRevision;
    if (changed) {
      this.runtime = { bootId: nextBoot, configRevision: nextRevision };
    }
    this.ready = ready && valid;
    return changed;
  }

  stop(): void {
    ++this.generation;
    ++this.actionEpoch;
    this.fresh = false;
    this.sessionId = '';
    this.sequence = 0;
    const socket = this.socket;
    this.socket = undefined;
    socket?.stop();
    this.state = 'closed';
  }

  loseBaseline(): void {
    ++this.actionEpoch;
    this.fresh = false;
    this.sessionId = '';
    this.sequence = 0;
  }

  accept(bootId: string, revision: number, session: string, sequence: number, kind: string): boolean {
    if (bootId !== this.runtime.bootId || revision !== this.runtime.configRevision) { return false; }
    if (session === this.sessionId && sequence <= this.sequence) { return false; }
    if (this.sessionId === '') {
      if (kind !== 'snapshot' || sequence !== 1) { this.invalid(); return false; }
    } else if (session !== this.sessionId || sequence !== this.sequence + 1 || kind === 'snapshot') {
      this.invalid();
      return false;
    }
    this.sessionId = session;
    this.sequence = sequence;
    this.fresh = true;
    return true;
  }

  invalid(): void { this.socket?.fail('diagnostics_invalid_data'); }
}

function recordFacetsAfterToggle(facets: RecordFacets, field: string, option: string): RecordFacets {
  const next: RecordFacets = {};
  for (const key of Object.keys(facets)) { next[key] = facets[key].slice(); }
  const selected = next[field] ?? [];
  next[field] = selected.includes(option) ? selected.filter((item: string): boolean => item !== option) :
    [...selected, option];
  return next;
}

function recordWidthsCopy(widths: Record<string, number>): Record<string, number> {
  const copy: Record<string, number> = {};
  for (const key of Object.keys(widths)) { copy[key] = widths[key]; }
  return copy;
}

function connectionWithTraffic(record: DiagnosticConnection, upload: number, download: number): DiagnosticConnection {
  if (record.upload === upload && record.download === download) { return record; }
  const next: DiagnosticConnection = {
    id: record.id, start: record.start, metadata: record.metadata, chains: record.chains,
    providerChains: record.providerChains, rule: record.rule, rulePayload: record.rulePayload,
    upload: upload, download: download
  };
  return next;
}

function historicalConnection(record: DiagnosticConnection, previous?: ConnectionRecordView): ConnectionRecordView {
  if (previous !== undefined && previous.connection === record && previous.uploadSpeed === 0 &&
    previous.downloadSpeed === 0 && previous.rankSpeed === 0 && previous.duration === 0) { return previous; }
  const view: ConnectionRecordView = {
    key: record.id, connection: record, uploadSpeed: 0, downloadSpeed: 0, rankSpeed: 0, duration: 0
  };
  return view;
}

function sameDnsRecord(first: DiagnosticDnsRecord, second: DiagnosticDnsRecord): boolean {
  return first.domain === second.domain && first.type === second.type && first.initiator === second.initiator &&
    first.upstream === second.upstream && first.rcode === second.rcode && first.error === second.error &&
    first.cached === second.cached && first.delay === second.delay && first.time === second.time &&
    first.answers.length === second.answers.length &&
    first.answers.every((answer: string, index: number): boolean => answer === second.answers[index]);
}

@ObservedV2
export class ConnectionRecordsStore {
  @Trace query: string = '';
  @Trace facets: RecordFacets = {};
  @Trace streamState: ControllerSocketState = 'closed';
  @Trace error: string = '';
  @Trace preferenceError: string = '';
  @Trace sampledAt: number = 0;
  @Trace dropped: number = 0;
  @Trace evicted: number = 0;
  @Trace interruptions: number = 0;
  @Trace following: boolean = true;
  @Trace actionPending: boolean = false;
  @Trace notice: string = '';
  @Trace noticeError: string = '';
  @Trace noticeSerial: number = 0;
  @Trace version: number = 0;
  @Trace selectedId: string = '';
  @Trace feed: RequestFeed = 'live';
  @Trace grouping: RecordGrouping = 'none';
  readonly source: KeyedListSource<ConnectionListRow> = new KeyedListSource<ConnectionListRow>();
  private animateList?: (apply: () => void) => void;
  private session: RecordStreamSession = new RecordStreamSession();
  private history: RecordHistory<DiagnosticConnection> = new RecordHistory<DiagnosticConnection>(2000, 4000);
  private live: Map<string, DiagnosticConnection> = new Map<string, DiagnosticConnection>();
  private ranker: TrackerSpeedRanker = new TrackerSpeedRanker();
  private liveViews: ConnectionRecordView[] = [];
  private historyViews: Map<string, ConnectionRecordView> = new Map<string, ConnectionRecordView>();
  private rows: Map<string, ConnectionListRow> = new Map<string, ConnectionListRow>();
  private expanded: Set<string> = new Set<string>();
  @Trace private filteredCount: number = 0;
  @Trace private liveCount: number = 0;
  @Trace private historyCount: number = 0;
  @Trace private connectionReady: boolean = false;
  @Trace private forwardingReady: boolean = false;
  @Trace private baselineReady: boolean = false;
  @Trace private selectedRecord?: ConnectionRecordView;
  private context?: common.UIAbilityContext;
  private feedVersion: number = 0;
  private groupingVersion: number = 0;
  private requestsWidthVersion: number = 0;
  private connectionsWidthVersion: number = 0;
  private preferenceLoad: number = 0;
  private preferenceReadFailed: boolean = false;
  @Trace private requestWidths: Record<string, number> = {};
  @Trace private liveWidths: Record<string, number> = {};
  @Trace private recentSort: RecordSort = { column: '', direction: '' };
  @Trace private liveSort: RecordSort = { column: '', direction: '' };
  private failedFeed?: RequestFeed;
  private failedGrouping?: RecordGrouping;
  private failedRequestWidths?: Record<string, number>;
  private failedLiveWidths?: Record<string, number>;
  private savedFeed: RequestFeed = 'live';
  private savedGrouping: RecordGrouping = 'none';
  private savedRequestWidths: Record<string, number> = {};
  private savedLiveWidths: Record<string, number> = {};

  get canAct(): boolean {
    return this.forwardingReady && this.synced && !this.actionPending;
  }
  get ready(): boolean { return this.connectionReady; }
  get synced(): boolean { return this.connectionReady && this.baselineReady && this.streamState === 'open'; }
  get totalRecords(): number { return this.feed === 'live' ? this.liveCount : this.historyCount; }
  get visibleRecords(): number { return this.filteredCount; }
  get activeRuntime(): DiagnosticRuntime {
    return { bootId: this.session.runtime.bootId, configRevision: this.session.runtime.configRevision };
  }
  get selected(): ConnectionRecordView | undefined { return this.selectedRecord; }
  get columnWidths(): Record<string, number> { return this.feed === 'live' ? this.liveWidths : this.requestWidths; }
  get sort(): RecordSort { return this.feed === 'live' ? this.liveSort : this.recentSort; }
  get anchorKey(): string { return this.history.anchor; }

  async load(context: common.UIAbilityContext, initialFeed?: RequestFeed,
    preserveFeed: boolean = false): Promise<void> {
    this.context = context;
    this.session.filesDir = context.filesDir;
    if (initialFeed !== undefined) {
      this.feed = initialFeed;
      this.expanded.clear();
      ++this.feedVersion;
      this.refresh();
    }
    this.syncStream();
    await this.readPreferences(initialFeed === undefined && !preserveFeed);
  }

  setListAnimation(animate?: (apply: () => void) => void): void { this.animateList = animate; }

  setVisible(visible: boolean): void {
    if (visible === this.session.visible) { return; }
    this.session.visible = visible;
    if (!visible) { this.stopStream(); this.clearNotice(); }
    else { this.syncStream(); }
  }

  setConnection(ready: boolean, bootId: string, configRevision: number, forwardingReady: boolean): void {
    this.forwardingReady = forwardingReady;
    if (!forwardingReady && this.actionPending) {
      ++this.session.actionEpoch;
      this.actionPending = false;
    }
    const changed = this.session.setRuntime(ready, bootId, configRevision);
    this.connectionReady = this.session.ready;
    if (changed || !this.session.ready) { this.stopStream(changed); }
    this.syncStream();
  }

  retry(): void {
    this.stopStream();
    this.error = '';
    this.syncStream();
  }

  setQuery(query: string): void { this.query = query; this.refresh(); }
  toggleFacet(field: string, option: string): void {
    this.facets = recordFacetsAfterToggle(this.facets, field, option);
    this.refresh();
  }
  setSort(sort: RecordSort): void {
    const copy: RecordSort = { column: sort.column, direction: sort.direction };
    if (this.feed === 'live') { this.liveSort = copy; } else { this.recentSort = copy; }
    this.refresh();
  }
  setFollowing(following: boolean): void {
    this.history.setFollowing(following);
    this.following = following;
    this.refresh();
  }
  setAnchor(key: string): void { this.history.anchor = key; }
  select(id: string): void {
    this.selectedId = id;
    this.selectedRecord = this.liveViews.find((record: ConnectionRecordView): boolean => record.key === id) ??
      this.historyViews.get(id);
  }
  clearNotice(): void { this.notice = ''; this.noticeError = ''; }
  toggleGroup(key: string): void {
    const group = key.startsWith('group:') ? key.slice(6) : key;
    if (this.expanded.has(group)) { this.expanded.delete(group); } else { this.expanded.add(group); }
    this.refresh();
  }
  facetOptions(field: string): string[] {
    return connectionFacetOptions(this.feed === 'live' ? this.liveViews : this.historyViews.values(),
      field, this.facets[field] ?? []);
  }

  setFeed(feed: RequestFeed): void {
    if (feed === this.feed) { return; }
    this.feed = feed;
    this.expanded.clear();
    const version = ++this.feedVersion;
    this.refresh();
    this.persistFeed(feed, version).catch((): void => {});
  }

  setGrouping(grouping: RecordGrouping): void {
    if (grouping === this.grouping) { return; }
    this.grouping = grouping;
    this.expanded.clear();
    const version = ++this.groupingVersion;
    this.refresh();
    this.persistGrouping(grouping, version).catch((): void => {});
  }

  async saveColumnWidths(widths: Record<string, number>): Promise<void> {
    const view: RecordView = this.feed === 'live' ? 'connections' : 'requests';
    const copy = recordWidthsCopy(widths);
    const version = view === 'connections' ? ++this.connectionsWidthVersion : ++this.requestsWidthVersion;
    if (view === 'connections') { this.liveWidths = copy; } else { this.requestWidths = copy; }
    ++this.version;
    try {
      if (this.context === undefined) { throw new Error('diagnostics_preferences_failed'); }
      await saveRecordColumnWidths(this.context, view, copy);
      if (view === 'connections') { this.savedLiveWidths = copy; } else { this.savedRequestWidths = copy; }
      if (view === 'connections' && version === this.connectionsWidthVersion) { this.failedLiveWidths = undefined; }
      if (view === 'requests' && version === this.requestsWidthVersion) { this.failedRequestWidths = undefined; }
      this.updatePreferenceError();
    } catch (e) {
      if (view === 'connections' && version === this.connectionsWidthVersion) {
        this.liveWidths = this.savedLiveWidths; this.failedLiveWidths = copy;
      }
      if (view === 'requests' && version === this.requestsWidthVersion) {
        this.requestWidths = this.savedRequestWidths; this.failedRequestWidths = copy;
      }
      this.preferenceError = 'diagnostics_preferences_failed';
      ++this.version;
      throw new Error('diagnostics_preferences_failed');
    }
  }

  async retryPreferences(): Promise<void> {
    if (this.failedFeed !== undefined) {
      const feed = this.failedFeed;
      this.feed = feed;
      await this.persistFeed(feed, ++this.feedVersion);
    }
    if (this.failedGrouping !== undefined) {
      const grouping = this.failedGrouping;
      this.grouping = grouping;
      await this.persistGrouping(grouping, ++this.groupingVersion);
    }
    if (this.failedRequestWidths !== undefined) {
      await this.retryWidths('requests', this.failedRequestWidths);
    }
    if (this.failedLiveWidths !== undefined) {
      await this.retryWidths('connections', this.failedLiveWidths);
    }
    await this.readPreferences();
    if (this.preferenceError !== '') { throw new Error('diagnostics_preferences_failed'); }
  }

  async closeOne(id: string): Promise<void> {
    if (id === '' || !this.live.has(id)) { return; }
    await this.close('one', id);
  }
  async closeAll(): Promise<void> { await this.close('all'); }

  private syncStream(): void {
    if (!this.session.shouldStart || this.session.socket !== undefined) { return; }
    const generation = ++this.session.generation;
    this.error = '';
    const socket = createConnectionsStream(this.activeRuntime,
      (frame: DiagnosticConnectionsFrame): void => {
        if (generation === this.session.generation && this.session.shouldStart) { this.applyFrame(frame); }
      }, (state: ControllerSocketState): void => { this.applyStreamState(state, generation); });
    this.session.socket = socket;
    socket.start(this.session.filesDir);
  }

  private applyStreamState(state: ControllerSocketState, generation: number): void {
    if (generation !== this.session.generation) { return; }
    this.session.state = state;
    this.streamState = state;
    if (state !== 'open') {
      if (this.session.fresh) { ++this.interruptions; }
      this.session.loseBaseline();
      this.baselineReady = false;
      this.actionPending = false;
      this.clearLive();
      if (state === 'failed') {
        this.error = this.session.socket?.failure === 'diagnostics_invalid_data' ?
          'diagnostics_invalid_data' : 'diagnostics_stream_failed';
      }
      this.refresh();
    }
  }

  private stopStream(resetRecords: boolean = false): void {
    this.session.stop();
    this.baselineReady = false;
    this.streamState = 'closed';
    this.actionPending = false;
    if (resetRecords) { this.clearRecords(); return; }
    this.clearLive();
    this.refresh();
  }

  private clearLive(): void { this.live.clear(); this.liveViews = []; this.ranker.reset(); }

  private clearRecords(): void {
    this.history.clear(); this.historyViews.clear(); this.clearLive(); this.expanded.clear();
    this.baselineReady = false;
    this.rows.clear(); this.selectedId = ''; this.sampledAt = 0; this.dropped = 0; this.evicted = 0;
    this.interruptions = 0; this.following = true; this.actionPending = false; this.error = '';
    this.clearNotice(); this.refresh();
  }

  private applyFrame(frame: DiagnosticConnectionsFrame): void {
    if (!this.session.accept(frame.bootId, frame.configRevision, frame.sessionId, frame.seq, frame.kind)) { return; }
    this.baselineReady = true;
    this.sampledAt = frame.sampledAt;
    this.dropped = frame.dropped;
    this.evicted = frame.evicted;
    this.error = '';
    if (frame.kind === 'snapshot' || frame.kind === 'reset') {
      this.live.clear();
      for (const connection of frame.live) { this.live.set(connection.id, connection); }
      this.history.replace(frame.recent, frame.kind === 'snapshot');
    } else {
      for (const connection of frame.opened) { this.live.set(connection.id, connection); }
      this.history.append(frame.opened);
      for (const traffic of frame.traffic) { this.applyTraffic(traffic); }
      for (const id of frame.closed) { this.live.delete(id); }
    }
    this.liveViews = this.ranker.rank(Array.from<DiagnosticConnection>(this.live.values()), frame.sampledAt);
    this.refresh(frame.kind === 'delta' && (this.feed === 'live' || this.following));
  }

  private applyTraffic(traffic: DiagnosticTraffic): void {
    const live = this.live.get(traffic.id);
    const previous = live ?? this.history.get(traffic.id);
    if (previous === undefined) { return; }
    const record = connectionWithTraffic(previous, traffic.upload, traffic.download);
    if (live !== undefined) { this.live.set(record.id, record); }
    this.history.update(record);
  }

  private currentViews(): ConnectionRecordView[] {
    if (this.feed === 'live') { return this.liveViews; }
    const next: Map<string, ConnectionRecordView> = new Map<string, ConnectionRecordView>();
    const records = this.history.values().map<ConnectionRecordView>((record: DiagnosticConnection): ConnectionRecordView => {
      const view = historicalConnection(record, this.historyViews.get(record.id));
      next.set(record.id, view);
      return view;
    });
    this.historyViews = next;
    records.reverse();
    return records;
  }

  private refresh(animate: boolean = false): void {
    // 即使当前显示 live，也保持详情所引用的 recent 统计同步且有界。
    if (this.feed === 'live') {
      const next: Map<string, ConnectionRecordView> = new Map<string, ConnectionRecordView>();
      for (const record of this.history.values()) {
        next.set(record.id, historicalConnection(record, this.historyViews.get(record.id)));
      }
      this.historyViews = next;
    }
    const filtered = filterConnections(this.currentViews(), this.query, this.facets);
    const ordered = sortConnections(filtered, this.sort);
    const groups = groupConnections(ordered, this.grouping);
    const nextRows: Map<string, ConnectionListRow> = new Map<string, ConnectionListRow>();
    const entries: ConnectionListRow[] = [];
    for (const group of groups) { this.appendGroup(group, nextRows, entries); }
    for (const key of this.expanded) {
      if (!nextRows.has(`group:${key}`)) { this.expanded.delete(key); }
    }
    this.rows = nextRows;
    const present = animate ? this.animateList : undefined;
    this.source.replace(entries, present === undefined ? undefined : (apply: () => void): void => {
      present((): void => {
        this.filteredCount = filtered.length;
        apply();
      });
    });
    this.filteredCount = filtered.length;
    this.liveCount = this.live.size;
    this.historyCount = this.history.count;
    this.selectedRecord = this.liveViews.find((record: ConnectionRecordView): boolean => record.key === this.selectedId) ??
      this.historyViews.get(this.selectedId);
    ++this.version;
  }

  private appendGroup(group: RecordGroup, next: Map<string, ConnectionListRow>, entries: ConnectionListRow[]): void {
    const expanded = this.expanded.has(group.key);
    if (this.grouping !== 'none') {
      const key = `group:${group.key}`;
      const row = this.rows.get(key) ?? new ConnectionListRow(key);
      row.group = group.title;
      row.groupCount = group.items.length;
      row.expanded = expanded;
      next.set(key, row); entries.push(row);
    }
    if (!expanded && this.grouping !== 'none') { return; }
    for (const record of group.items) {
      const key = record.key;
      const row = this.rows.get(key) ?? new ConnectionListRow(key);
      row.record = record;
      next.set(key, row); entries.push(row);
    }
  }

  private async close(scope: 'one' | 'all', id?: string): Promise<void> {
    if (!this.canAct) { return; }
    const epoch = this.session.actionEpoch;
    const generation = this.session.generation;
    const runtime = this.activeRuntime;
    this.actionPending = true;
    try {
      await closeDiagnosticConnections(this.session.filesDir, runtime, scope, id);
      if (this.actionCurrent(epoch, generation)) { this.publishNotice('closed', ''); }
    } catch (e) {
      const code = diagnosticError(e as Object);
      if (this.actionCurrent(epoch, generation) && code !== 'diagnostics_stale_runtime') {
        this.publishNotice('error', code);
      }
    } finally {
      if (epoch === this.session.actionEpoch && generation === this.session.generation) { this.actionPending = false; }
    }
  }

  private actionCurrent(epoch: number, generation: number): boolean {
    return epoch === this.session.actionEpoch && generation === this.session.generation && this.session.canAct;
  }
  private publishNotice(notice: string, error: string): void {
    this.notice = notice; this.noticeError = error; ++this.noticeSerial;
  }

  private async readPreferences(applyFeed: boolean = true): Promise<void> {
    const context = this.context;
    if (context === undefined) { return; }
    const load = ++this.preferenceLoad;
    const feedVersion = this.feedVersion;
    const groupingVersion = this.groupingVersion;
    const requestVersion = this.requestsWidthVersion;
    const liveVersion = this.connectionsWidthVersion;
    try {
      const snapshot: RecordPreferenceSnapshot = await loadRecordPreferences(context);
      if (load !== this.preferenceLoad) { return; }
      this.preferenceReadFailed = false;
      if (feedVersion === this.feedVersion) {
        this.savedFeed = snapshot.feed;
        if (applyFeed) { this.feed = snapshot.feed; }
      }
      if (groupingVersion === this.groupingVersion) { this.grouping = snapshot.grouping; this.savedGrouping = snapshot.grouping; }
      if (requestVersion === this.requestsWidthVersion) {
        this.requestWidths = snapshot.requests; this.savedRequestWidths = snapshot.requests;
      }
      if (liveVersion === this.connectionsWidthVersion) {
        this.liveWidths = snapshot.connections; this.savedLiveWidths = snapshot.connections;
      }
      this.updatePreferenceError();
      this.refresh();
    } catch (e) {
      if (load === this.preferenceLoad) {
        this.preferenceReadFailed = true; this.preferenceError = 'diagnostics_preferences_failed';
      }
    }
  }

  private async persistFeed(feed: RequestFeed, version: number): Promise<void> {
    try {
      if (this.context === undefined) { throw new Error('diagnostics_preferences_failed'); }
      await saveRecordFeed(this.context, feed);
      this.savedFeed = feed;
      if (version === this.feedVersion) { this.failedFeed = undefined; this.updatePreferenceError(); }
    } catch (e) {
      if (version === this.feedVersion) {
        this.feed = this.savedFeed; this.failedFeed = feed; this.preferenceError = 'diagnostics_preferences_failed'; this.refresh();
      }
    }
  }

  private async persistGrouping(grouping: RecordGrouping, version: number): Promise<void> {
    try {
      if (this.context === undefined) { throw new Error('diagnostics_preferences_failed'); }
      await saveRecordGrouping(this.context, grouping);
      this.savedGrouping = grouping;
      if (version === this.groupingVersion) { this.failedGrouping = undefined; this.updatePreferenceError(); }
    } catch (e) {
      if (version === this.groupingVersion) {
        this.grouping = this.savedGrouping; this.failedGrouping = grouping;
        this.preferenceError = 'diagnostics_preferences_failed'; this.refresh();
      }
    }
  }

  private async retryWidths(view: RecordView, widths: Record<string, number>): Promise<void> {
    if (this.context === undefined) { throw new Error('diagnostics_preferences_failed'); }
    const version = view === 'connections' ? ++this.connectionsWidthVersion : ++this.requestsWidthVersion;
    try {
      await saveRecordColumnWidths(this.context, view, widths);
      if (view === 'connections') {
        this.savedLiveWidths = widths;
        if (version === this.connectionsWidthVersion) {
          this.liveWidths = widths; this.failedLiveWidths = undefined;
        }
      } else {
        this.savedRequestWidths = widths;
        if (version === this.requestsWidthVersion) {
          this.requestWidths = widths; this.failedRequestWidths = undefined;
        }
      }
    } catch (e) {
      this.preferenceError = 'diagnostics_preferences_failed';
      throw new Error('diagnostics_preferences_failed');
    }
  }

  private updatePreferenceError(): void {
    this.preferenceError = this.preferenceReadFailed || this.failedFeed !== undefined || this.failedGrouping !== undefined ||
      this.failedRequestWidths !== undefined || this.failedLiveWidths !== undefined ? 'diagnostics_preferences_failed' : '';
  }
}

@ObservedV2
export class DnsRecordsStore {
  @Trace query: string = '';
  @Trace facets: RecordFacets = {};
  @Trace streamState: ControllerSocketState = 'closed';
  @Trace error: string = '';
  @Trace preferenceError: string = '';
  @Trace sampledAt: number = 0;
  @Trace dropped: number = 0;
  @Trace evicted: number = 0;
  @Trace interruptions: number = 0;
  @Trace following: boolean = true;
  @Trace actionPending: boolean = false;
  @Trace notice: string = '';
  @Trace noticeError: string = '';
  @Trace noticeSerial: number = 0;
  @Trace version: number = 0;
  @Trace selectedId: string = '';
  readonly source: KeyedListSource<DnsListRow> = new KeyedListSource<DnsListRow>();
  private animateList?: (apply: () => void) => void;
  private session: RecordStreamSession = new RecordStreamSession();
  private history: RecordHistory<DiagnosticDnsRecord> = new RecordHistory<DiagnosticDnsRecord>(3000, 6000);
  private rows: Map<string, DnsListRow> = new Map<string, DnsListRow>();
  @Trace private filteredCount: number = 0;
  @Trace private historyCount: number = 0;
  @Trace private connectionReady: boolean = false;
  @Trace private forwardingReady: boolean = false;
  @Trace private baselineReady: boolean = false;
  @Trace private selectedRecord?: DiagnosticDnsRecord;
  private context?: common.UIAbilityContext;
  @Trace private widths: Record<string, number> = {};
  private widthVersion: number = 0;
  private preferenceLoad: number = 0;
  private preferenceReadFailed: boolean = false;
  private failedWidths?: Record<string, number>;
  private savedWidths: Record<string, number> = {};
  @Trace private tableSort: RecordSort = { column: '', direction: '' };

  get canAct(): boolean {
    return this.forwardingReady && this.synced && !this.actionPending;
  }
  get ready(): boolean { return this.connectionReady; }
  get synced(): boolean { return this.connectionReady && this.baselineReady && this.streamState === 'open'; }
  get totalRecords(): number { return this.historyCount; }
  get visibleRecords(): number { return this.filteredCount; }
  get activeRuntime(): DiagnosticRuntime {
    return { bootId: this.session.runtime.bootId, configRevision: this.session.runtime.configRevision };
  }
  get selected(): DiagnosticDnsRecord | undefined { return this.selectedRecord; }
  get columnWidths(): Record<string, number> { return this.widths; }
  get sort(): RecordSort { return this.tableSort; }
  get anchorKey(): string { return this.history.anchor; }

  async load(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.session.filesDir = context.filesDir;
    this.syncStream();
    await this.readPreferences();
  }

  setListAnimation(animate?: (apply: () => void) => void): void { this.animateList = animate; }

  setVisible(visible: boolean): void {
    if (visible === this.session.visible) { return; }
    this.session.visible = visible;
    if (!visible) { this.stopStream(); this.clearNotice(); }
    else { this.syncStream(); }
  }

  setConnection(ready: boolean, bootId: string, configRevision: number, forwardingReady: boolean): void {
    this.forwardingReady = forwardingReady;
    if (!forwardingReady && this.actionPending) {
      ++this.session.actionEpoch;
      this.actionPending = false;
    }
    const changed = this.session.setRuntime(ready, bootId, configRevision);
    this.connectionReady = this.session.ready;
    if (changed || !this.session.ready) { this.stopStream(changed); }
    this.syncStream();
  }

  retry(): void { this.stopStream(); this.error = ''; this.syncStream(); }
  setQuery(query: string): void { this.query = query; this.refresh(); }
  toggleFacet(field: string, option: string): void {
    this.facets = recordFacetsAfterToggle(this.facets, field, option); this.refresh();
  }
  setSort(sort: RecordSort): void { this.tableSort = { column: sort.column, direction: sort.direction }; this.refresh(); }
  setFollowing(following: boolean): void {
    this.history.setFollowing(following); this.following = following; this.refresh();
  }
  setAnchor(key: string): void { this.history.anchor = key; }
  select(id: string): void { this.selectedId = id; this.selectedRecord = this.history.get(id); }
  clearNotice(): void { this.notice = ''; this.noticeError = ''; }
  facetOptions(field: string): string[] { return dnsFacetOptions(this.history.values(), field, this.facets[field] ?? []); }

  async saveColumnWidths(widths: Record<string, number>): Promise<void> {
    const copy = recordWidthsCopy(widths);
    const version = ++this.widthVersion;
    this.widths = copy;
    ++this.version;
    try {
      if (this.context === undefined) { throw new Error('diagnostics_preferences_failed'); }
      await saveRecordColumnWidths(this.context, 'dns', copy);
      this.savedWidths = copy;
      if (version === this.widthVersion) {
        this.failedWidths = undefined;
        this.preferenceError = this.preferenceReadFailed ? 'diagnostics_preferences_failed' : '';
      }
    } catch (e) {
      if (version === this.widthVersion) {
        this.widths = this.savedWidths; this.failedWidths = copy; this.preferenceError = 'diagnostics_preferences_failed';
        ++this.version;
      }
      throw new Error('diagnostics_preferences_failed');
    }
  }

  async retryPreferences(): Promise<void> {
    if (this.failedWidths !== undefined) { await this.saveColumnWidths(this.failedWidths); }
    await this.readPreferences();
    if (this.preferenceError !== '') { throw new Error('diagnostics_preferences_failed'); }
  }

  async clearCache(): Promise<void> {
    if (!this.canAct) { return; }
    const epoch = this.session.actionEpoch;
    const generation = this.session.generation;
    this.actionPending = true;
    try {
      await clearDiagnosticDnsCache(this.session.filesDir, this.activeRuntime);
      if (this.actionCurrent(epoch, generation)) { this.publishNotice('cacheCleared', ''); }
    } catch (e) {
      const code = diagnosticError(e as Object);
      if (this.actionCurrent(epoch, generation) && code !== 'diagnostics_stale_runtime') {
        this.publishNotice('error', code);
      }
    } finally {
      if (epoch === this.session.actionEpoch && generation === this.session.generation) { this.actionPending = false; }
    }
  }

  private syncStream(): void {
    if (!this.session.shouldStart || this.session.socket !== undefined) { return; }
    const generation = ++this.session.generation;
    this.error = '';
    const socket = createDnsStream(this.activeRuntime, (frame: DiagnosticDnsFrame): void => {
      if (generation === this.session.generation && this.session.shouldStart) { this.applyFrame(frame); }
    }, (state: ControllerSocketState): void => { this.applyStreamState(state, generation); });
    this.session.socket = socket;
    socket.start(this.session.filesDir);
  }

  private applyStreamState(state: ControllerSocketState, generation: number): void {
    if (generation !== this.session.generation) { return; }
    this.session.state = state; this.streamState = state;
    if (state !== 'open') {
      if (this.session.fresh) { ++this.interruptions; }
      this.session.loseBaseline(); this.actionPending = false;
      this.baselineReady = false;
      if (state === 'failed') {
        this.error = this.session.socket?.failure === 'diagnostics_invalid_data' ?
          'diagnostics_invalid_data' : 'diagnostics_stream_failed';
      }
    }
  }

  private stopStream(resetRecords: boolean = false): void {
    this.session.stop(); this.streamState = 'closed'; this.actionPending = false;
    this.baselineReady = false;
    if (resetRecords) { this.clearRecords(); }
  }

  private clearRecords(): void {
    this.history.clear(); this.rows.clear(); this.selectedId = ''; this.sampledAt = 0;
    this.baselineReady = false;
    this.dropped = 0; this.evicted = 0; this.interruptions = 0; this.following = true;
    this.actionPending = false; this.error = ''; this.clearNotice(); this.refresh();
  }

  private applyFrame(frame: DiagnosticDnsFrame): void {
    if (!this.session.accept(frame.bootId, frame.configRevision, frame.sessionId, frame.seq, frame.kind)) { return; }
    this.baselineReady = true;
    this.sampledAt = frame.sampledAt; this.dropped = frame.dropped; this.evicted = frame.evicted; this.error = '';
    if (frame.kind === 'delta') {
      this.history.append(frame.added);
    } else {
      const records = frame.records.map<DiagnosticDnsRecord>((record: DiagnosticDnsRecord): DiagnosticDnsRecord => {
        const previous = this.history.get(record.id);
        return previous !== undefined && sameDnsRecord(previous, record) ? previous : record;
      });
      this.history.replace(records, frame.kind === 'snapshot');
    }
    this.refresh(frame.kind === 'delta' && this.following);
  }

  private refresh(animate: boolean = false): void {
    const ordered = this.history.values().slice().reverse();
    const filtered = filterDns(ordered, this.query, this.facets);
    const records = sortDns(filtered, this.tableSort);
    const next: Map<string, DnsListRow> = new Map<string, DnsListRow>();
    const rows: DnsListRow[] = [];
    for (const record of records) {
      const previous = this.rows.get(record.id);
      const row: DnsListRow = previous !== undefined && previous.record === record ? previous : { key: record.id, record: record };
      next.set(row.key, row); rows.push(row);
    }
    this.rows = next;
    const present = animate ? this.animateList : undefined;
    this.source.replace(rows, present === undefined ? undefined : (apply: () => void): void => {
      present((): void => {
        this.filteredCount = filtered.length;
        apply();
      });
    });
    this.filteredCount = filtered.length;
    ++this.version;
    this.historyCount = this.history.count;
    this.selectedRecord = this.history.get(this.selectedId);
  }

  private actionCurrent(epoch: number, generation: number): boolean {
    return epoch === this.session.actionEpoch && generation === this.session.generation && this.session.canAct;
  }
  private publishNotice(notice: string, error: string): void {
    this.notice = notice; this.noticeError = error; ++this.noticeSerial;
  }

  private async readPreferences(): Promise<void> {
    const context = this.context;
    if (context === undefined) { return; }
    const load = ++this.preferenceLoad;
    const version = this.widthVersion;
    try {
      const snapshot: RecordPreferenceSnapshot = await loadRecordPreferences(context);
      if (load !== this.preferenceLoad) { return; }
      this.preferenceReadFailed = false;
      if (version === this.widthVersion) { this.widths = snapshot.dns; this.savedWidths = snapshot.dns; }
      this.preferenceError = this.failedWidths === undefined ? '' : 'diagnostics_preferences_failed';
      ++this.version;
    } catch (e) {
      if (load === this.preferenceLoad) {
        this.preferenceReadFailed = true; this.preferenceError = 'diagnostics_preferences_failed';
      }
    }
  }
}

export const connectionRecords: ConnectionRecordsStore = new ConnectionRecordsStore();
export const dnsRecords: DnsRecordsStore = new DnsRecordsStore();
