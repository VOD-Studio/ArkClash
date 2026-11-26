import { common } from '@kit.AbilityKit';
import { LengthMetrics, UIUtils } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Connection, connection } from '../../client/Connection';
import { ControllerSocket, ControllerSocketState } from '../../client/ControllerSocket';
import { GeneralSettingsState, generalSettingsState } from '../../client/GeneralSettings';
import { clearDiagnosticLogs, exportLogs, LogFrame, LogRecord, logStream, LOG_LIMIT } from '../../client/Logs';
import { AppGlyph } from '../../components/AppGlyph';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { EmptyState } from '../../components/EmptyState';
import { KeyedListSource } from '../../components/KeyedListSource';
import { uiResourceText } from '../../components/ResourceText';
import { ScrollControls } from '../../components/ScrollControls';
import { ScrollDestination } from '../../components/ScrollDestination';
import {
  COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE,
  PAGE_GUTTER, SHEET_HEADER_HEIGHT
} from '../../components/Theme';
import { GeneralSettings, GENERAL_LEVELS } from '../../shared/GeneralSettings';
import { LogHistory, LogListRow } from './LogHistory';
import { logCopyText, logLevelLabel, logSummaryLabel } from './LogLabels';
import { logLevelInk, logLevelSurface, LogRecordDetails, LogRecordItem } from './LogRecordView';
import { RECORD_LIST_ANIMATION, recordListTransition, RecordListViewport } from './RecordList';

const LOG_FILTER_LEVELS: string[] = ['error', 'warning', 'info', 'debug'];
const LOG_MORE_MENU_WIDTH = 240;
const LOG_GAP_TOAST_COOLDOWN_MS = 15000;
type LogMenuLevel = 'root' | 'level';

interface CachedLogsState {
  bootId: string;
  records: LogRecord[];
  dropped: number;
}

let cachedLogsState: CachedLogsState | undefined = undefined;

function logMenuLevelTransition(offsetX: number): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: offsetX }))
      .animation({ delay: 60, duration: 150, curve: Curve.EaseOut }),
    TransitionEffect.opacity(0).animation({ duration: 60, curve: Curve.EaseOut })
  );
}

function cloneGeneralSettings(saved: GeneralSettings): GeneralSettings {
  return {
    revision: saved.revision,
    ports: saved.ports,
    authentication: saved.authentication,
    controllerSecret: saved.controllerSecret,
    userAgent: saved.userAgent,
    userAgents: saved.userAgents,
    appendSystemDns: saved.appendSystemDns,
    hosts: saved.hosts,
    delayTimeout: saved.delayTimeout,
    closeConnections: saved.closeConnections,
    logLevel: saved.logLevel,
    captureLogs: saved.captureLogs,
    coreOverrides: saved.coreOverrides
  };
}

@ComponentV2
export struct LogsPage {
  @Param foreground: boolean = false;
  @Param reduceMotion: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private settings: GeneralSettingsState = generalSettingsState;
  @Local private shown: boolean = false;
  @Local private streamState: ControllerSocketState = 'closed';
  @Local private searchShown: boolean = false;
  @Local private query: string = '';
  @Local private levelFilters: string[] = [];
  @Local private draftLevels: string[] = [];
  @Local private levelCounts: Record<string, number> = {};
  @Local private filtering: boolean = false;
  @Local private moreShown: boolean = false;
  @Local private moreLevel: LogMenuLevel = 'root';
  @Local private paused: boolean = false;
  @Local private pending: number = 0;
  @Local private animatedBatch: number = 0;
  @Local private isExporting: boolean = false;
  @Local private isClearing: boolean = false;
  @Local private isUpdatingSettings: boolean = false;
  @Local private detailsShown: boolean = false;
  @Local private selected?: LogListRow;
  @Local private shownCount: number = 0;
  @Local private recordCount: number = 0;
  private socket?: ControllerSocket;
  private boot: string = '';
  private session: string = '';
  private seq: number = 0;
  private seenDropped: number = -1;
  private gapToastAt: number = 0;
  private readonly labels: Map<number, string> = new Map<number, string>();
  private readonly history: LogHistory = new LogHistory(LOG_LIMIT, (record: LogRecord): string => this.summary(record));
  private readonly viewport: RecordListViewport = new RecordListViewport();
  private readonly arrivalTransition: TransitionEffect = recordListTransition(-8);
  private readonly emptyTransition: TransitionEffect = recordListTransition();
  private readonly pillTransition: TransitionEffect = TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: 180, curve: Curve.EaseOut }),
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 8 }))
      .animation({ duration: 140, curve: Curve.EaseIn })
  );
  private readonly moreTransition: TransitionEffect = TransitionEffect.asymmetric(
    TransitionEffect.scale({ x: 0.86, y: 0.86, centerX: '90%', centerY: 0 })
      .combine(TransitionEffect.opacity(0)).animation({ duration: 210, curve: Curve.EaseOut }),
    TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '90%', centerY: 0 })
      .combine(TransitionEffect.opacity(0)).animation({ duration: 140, curve: Curve.EaseIn })
  );
  private readonly rootTransition: TransitionEffect = logMenuLevelTransition(-16);
  private readonly submenuTransition: TransitionEffect = logMenuLevelTransition(16);
  private detailOpen: boolean = false;
  private filterOpen: boolean = false;
  private followingBeforeDetail: boolean = false;
  private readonly rows: KeyedListSource<LogListRow> = new KeyedListSource<LogListRow>();

  aboutToAppear(): void {
    if (!this.settings.loaded) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settings.load(context).catch((): void => {});
    }
    if (this.settings.saved.captureLogs && this.conn.coreReady && this.conn.bootId !== '' &&
      cachedLogsState !== undefined && cachedLogsState.bootId === this.conn.bootId &&
      cachedLogsState.records.length > 0) {
      this.boot = this.conn.bootId;
      this.seenDropped = cachedLogsState.dropped;
      this.history.receive(cachedLogsState.records, 'snapshot', true);
      this.recordCount = this.history.window.latestCount;
      this.refreshRows(false, false);
    }
  }

  aboutToDisappear(): void {
    this.shown = false;
    this.sync();
  }

  @Computed
  get active(): boolean {
    return this.shown && this.foreground;
  }

  @Computed
  get hasFilters(): boolean {
    return this.levelFilters.length > 0;
  }

  @Computed
  get canClear(): boolean {
    return this.settings.saved.captureLogs && this.conn.coreReady && this.conn.bootId !== '' &&
      this.recordCount > 0 && !this.isClearing;
  }

  private emptyTitle(): ResourceStr {
    if (!this.settings.saved.captureLogs) { return $r('app.string.logs_capture_off'); }
    if (this.settings.saved.logLevel === 'silent') { return $r('app.string.logs_silent'); }
    if (!this.conn.coreReady || this.streamState === 'failed' || this.streamState === 'retrying') {
      return $r('app.string.logs_disconnected');
    }
    if (this.streamState === 'connecting') { return $r('app.string.logs_connecting'); }
    if (this.recordCount > 0) { return $r('app.string.logs_no_matches'); }
    return $r('app.string.logs_empty');
  }

  private emptyHint(): ResourceStr {
    if (!this.settings.saved.captureLogs) { return $r('app.string.logs_capture_off_hint'); }
    if (this.settings.saved.logLevel === 'silent') { return $r('app.string.logs_silent_hint'); }
    if (!this.conn.coreReady || this.streamState === 'failed' || this.streamState === 'retrying') {
      return $r('app.string.logs_disconnected_hint');
    }
    if (this.streamState === 'connecting') { return ''; }
    if (this.recordCount > 0) { return $r('app.string.diagnostics_adjust_filters'); }
    const levelText = uiResourceText(this.getUIContext(), logLevelLabel(this.settings.saved.logLevel));
    return $r('app.string.logs_empty_hint', levelText);
  }

  private emptyAction(): ResourceStr {
    if (!this.settings.saved.captureLogs) { return $r('app.string.logs_enable_capture'); }
    if (this.settings.saved.logLevel === 'silent') { return $r('app.string.logs_set_info_level'); }
    if (this.conn.coreReady && this.streamState === 'failed' && this.recordCount === 0) {
      return $r('app.string.action_retry');
    }
    if (this.recordCount > 0 && (this.query !== '' || this.levelFilters.length > 0)) {
      return $r('app.string.logs_clear_filters');
    }
    return '';
  }

  @Monitor('foreground', 'conn.coreReady', 'conn.bootId', 'settings.saved')
  sync(): void {
    if (!this.settings.saved.captureLogs) {
      cachedLogsState = undefined;
      this.viewport.activate(false);
      this.dismissOverlays();
      this.stop();
      this.clear();
      this.boot = '';
      return;
    }
    if (!this.shown || !this.foreground) {
      this.viewport.activate(false);
      this.dismissOverlays();
      this.stop();
      return;
    }
    this.viewport.activate(true);
    if (!this.conn.coreReady || this.conn.bootId === '') {
      this.stop();
      return;
    }
    if (this.boot !== this.conn.bootId) {
      if (cachedLogsState !== undefined && cachedLogsState.bootId !== this.conn.bootId) {
        cachedLogsState = undefined;
      }
      this.stop();
      this.clear();
      this.boot = this.conn.bootId;
    }
    if (this.socket === undefined) {
      this.socket = logStream(this.boot,
        (frame: LogFrame): void => this.receive(frame),
        (state: ControllerSocketState): void => {
          this.streamState = state;
        });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.socket.start(context.filesDir);
    }
  }

  private dismissOverlays(): void {
    this.moreShown = false;
    this.filtering = false;
    this.detailsShown = false;
    this.selected = undefined;
  }

  private stop(): void {
    this.socket?.stop();
    this.socket = undefined;
    this.session = '';
    this.seq = 0;
  }

  private clear(): void {
    this.labels.clear();
    this.followingBeforeDetail = false;
    this.selected = undefined;
    this.detailsShown = false;
    this.history.clear();
    this.seenDropped = -1;
    this.gapToastAt = 0;
    this.recordCount = 0;
    this.paused = false;
    this.refreshRows();
  }

  private notifyGap(): void {
    const now = Date.now();
    if (now - this.gapToastAt < LOG_GAP_TOAST_COOLDOWN_MS) { return; }
    this.gapToastAt = now;
    this.toast($r('app.string.logs_gap'));
  }

  private summary(record: LogRecord): string {
    const label = logSummaryLabel(record);
    if (typeof label === 'string') { return label; }
    const cached = this.labels.get(label.id);
    if (cached !== undefined) { return cached; }
    const text = uiResourceText(this.getUIContext(), label);
    this.labels.set(label.id, text);
    return text;
  }

  private receive(frame: LogFrame): void {
    const newSession = frame.kind === 'snapshot' && frame.seq === 1 && frame.sessionId !== this.session;
    if (frame.kind === 'snapshot' && frame.seq === 1) {
      const previousDropped = this.seenDropped;
      this.session = frame.sessionId;
      this.seenDropped = frame.dropped;
      if (previousDropped >= 0 && frame.dropped > previousDropped) {
        this.notifyGap();
      }
    } else if (frame.sessionId !== this.session || frame.seq !== this.seq + 1) {
      this.notifyGap();
      this.socket?.fail('log_sequence');
      return;
    } else if (frame.kind === 'reset' && frame.logs.length === 0) {
      this.seenDropped = frame.dropped;
    } else if (frame.dropped > this.seenDropped) {
      const hadBaseline = this.seenDropped >= 0;
      this.seenDropped = frame.dropped;
      if (hadBaseline) {
        this.notifyGap();
      }
    }
    this.seq = frame.seq;
    this.history.receive(frame.logs, frame.kind, newSession);
    this.recordCount = this.history.window.latestCount;
    if (this.boot !== '') {
      cachedLogsState = {
        bootId: this.boot,
        records: this.history.window.latest().map((row: LogListRow): LogRecord => row.record),
        dropped: this.seenDropped
      };
    }
    this.refreshRows(frame.kind === 'delta', newSession);
  }

  private refreshRows(delta: boolean = false, forceTop: boolean = false): void {
    const filtered = this.history.filter(this.query, this.levelFilters);
    const animate = delta && this.active && !this.reduceMotion && !this.paused;
    this.animatedBatch = animate ? this.history.batch : 0;
    this.rows.replace(filtered, animate ? (apply: () => void): void => {
      this.getUIContext().animateTo(RECORD_LIST_ANIMATION, apply);
    } : undefined, delta);
    this.shownCount = filtered.length;
    this.pending = this.history.pending;
    this.viewport.reconcile<LogListRow>(this.getUIContext(), this.rows, !this.paused, this.history.window.anchor, forceTop);
  }

  private setPaused(paused: boolean): void {
    if (this.paused === paused) { return; }
    this.paused = paused;
    this.history.setFollowing(!paused);
    this.refreshRows(false, !paused);
  }

  private backToLatest(): void {
    this.setPaused(false);
  }

  private toggleLevelFilter(level: string): void {
    if (this.levelFilters.includes(level)) {
      this.levelFilters = this.levelFilters.filter((item: string): boolean => item !== level);
    } else {
      this.levelFilters = LOG_FILTER_LEVELS.filter((item: string): boolean =>
        item === level || this.levelFilters.includes(item));
    }
    this.refreshRows(false, true);
  }

  private openFilterSheet(): void {
    if (!this.active || this.filtering || this.filterOpen || this.detailsShown || this.detailOpen || this.moreShown) {
      return;
    }
    this.draftLevels = this.levelFilters.slice();
    this.levelCounts = this.history.levelCounts();
    this.filtering = true;
  }

  private toggleDraftLevel(level: string): void {
    if (this.draftLevels.includes(level)) {
      this.draftLevels = this.draftLevels.filter((item: string): boolean => item !== level);
    } else {
      this.draftLevels = LOG_FILTER_LEVELS.filter((item: string): boolean =>
        item === level || this.draftLevels.includes(item));
    }
  }

  private applyFilterSheet(): void {
    this.levelFilters = this.draftLevels.slice();
    this.filtering = false;
    this.refreshRows(false, true);
  }

  private openMore(): void {
    if (!this.active || this.moreShown || this.filtering || this.filterOpen || this.detailsShown || this.detailOpen) {
      return;
    }
    this.moreLevel = 'root';
    this.moreShown = true;
  }

  private dismissMore(): void {
    if (!this.moreShown) { return; }
    this.moreShown = false;
  }

  private changeMoreLevel(from: LogMenuLevel, to: LogMenuLevel): void {
    if (!this.active || !this.moreShown || this.moreLevel !== from) { return; }
    if (this.reduceMotion) {
      this.moreLevel = to;
      return;
    }
    this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseOut }, (): void => {
      UIUtils.applySync<void>((): void => { this.moreLevel = to; });
    });
  }

  private openDetails(row: LogListRow): void {
    if (!this.active || this.filtering || this.filterOpen || this.moreShown || this.detailsShown || this.detailOpen) {
      return;
    }
    this.followingBeforeDetail = !this.paused;
    if (!this.paused) { this.setPaused(true); }
    this.selected = row;
    this.detailsShown = true;
  }

  private closeDetails(): void {
    this.detailOpen = false;
    this.selected = undefined;
    if (this.followingBeforeDetail && this.paused && this.pending === 0 && this.active) {
      this.setPaused(false);
    }
    this.followingBeforeDetail = false;
  }

  private toast(message: ResourceStr): void {
    if (this.active) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private async copyText(text: string): Promise<void> {
    if (text === '' || !this.active) { return; }
    let message: Resource = $r('app.string.diagnostics_copied');
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
    } catch (_error) {
      message = $r('app.string.diagnostics_copy_failed');
    }
    this.toast(message);
  }

  private async copySelected(): Promise<void> {
    const row = this.selected;
    if (row === undefined) { return; }
    await this.copyText(logCopyText(row.record, row.summary));
  }

  private async saveFile(): Promise<void> {
    if (this.isExporting || this.recordCount === 0) { return; }
    this.isExporting = true;
    const snapshot = this.history.window.latest().map((row: LogListRow): LogRecord => row.record);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await exportLogs(context, snapshot)) {
        this.toast($r('app.string.logs_exported'));
      }
    } catch (_error) {
      this.toast($r('app.string.logs_export_failed'));
    } finally {
      this.isExporting = false;
    }
  }

  private async clearCoreLogs(): Promise<void> {
    const bootId = this.conn.bootId;
    if (!this.canClear || bootId === '') { return; }
    this.isClearing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await clearDiagnosticLogs(context.filesDir, bootId);
      this.toast($r('app.string.logs_cleared'));
    } catch (_error) {
      this.toast($r('app.string.logs_clear_failed'));
    } finally {
      this.isClearing = false;
    }
  }

  private async updateLogSettings(capture: boolean, level?: string): Promise<void> {
    if (this.isUpdatingSettings) { return; }
    this.isUpdatingSettings = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!this.settings.loaded) {
        await this.settings.load(context);
      }
      const draft = cloneGeneralSettings(this.settings.saved);
      draft.captureLogs = capture;
      if (level !== undefined) { draft.logLevel = level; }
      await this.settings.save(context, draft);
      this.toast($r('app.string.general_saved'));
    } catch (_error) {
      this.toast($r('app.string.general_save_failed'));
    } finally {
      this.isUpdatingSettings = false;
    }
  }

  private handleEmptyAction(): void {
    if (!this.settings.saved.captureLogs) {
      const nextLevel = this.settings.saved.logLevel === 'silent' ? 'info' : undefined;
      this.updateLogSettings(true, nextLevel);
      return;
    }
    if (this.settings.saved.logLevel === 'silent') {
      this.updateLogSettings(true, 'info');
      return;
    }
    if (this.conn.coreReady && this.streamState === 'failed' && this.recordCount === 0) {
      this.stop();
      this.sync();
      return;
    }
    if (this.recordCount > 0) {
      this.query = '';
      this.levelFilters = [];
      this.searchShown = false;
      this.refreshRows(false, true);
    }
  }

  @Builder
  Header() { DestinationTitle({ titleText: $r('app.string.tools_logs') }) }

  @Builder
  MorePopup() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.moreLevel === 'root') {
        Column() {
          LogMenuRow({
            title: $r('app.string.logs_level_menu'),
            subtitle: logLevelLabel(this.settings.saved.logLevel),
            symbolIcon: $r('sys.symbol.slider_horizontal_2'),
            endGlyph: 'chevronForward',
            interactive: !this.isUpdatingSettings,
            onPress: (): void => this.changeMoreLevel('root', 'level')
          })
          LogMenuRow({
            title: $r('app.string.general_capture_logs'),
            symbolIcon: $r('sys.symbol.waveform_path_ecg_square'),
            selected: this.settings.saved.captureLogs,
            reduceMotion: this.reduceMotion,
            interactive: !this.isUpdatingSettings,
            onPress: (): void => {
              const nextCapture = !this.settings.saved.captureLogs;
              this.dismissMore();
              this.updateLogSettings(nextCapture);
            }
          })
          Divider().color(this.appStyle.palette.divider).margin({ left: 12, right: 12, top: 4, bottom: 4 })
          LogMenuRow({
            title: $r('app.string.logs_clear'),
            symbolIcon: $r('sys.symbol.trash'),
            interactive: this.canClear,
            onPress: (): void => {
              this.dismissMore();
              this.clearCoreLogs();
            }
          })
          LogMenuRow({
            title: $r('app.string.logs_export'),
            symbolIcon: $r('sys.symbol.arrow_down_to_line'),
            interactive: !this.isExporting && this.recordCount > 0,
            onPress: (): void => {
              this.dismissMore();
              this.saveFile();
            }
          })
        }
        .width('100%')
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.rootTransition)
      } else {
        Column() {
          LogMenuRow({
            title: $r('app.string.logs_level_menu'),
            symbolIcon: $r('sys.symbol.slider_horizontal_2'),
            endGlyph: 'chevronUp',
            onPress: (): void => this.changeMoreLevel('level', 'root')
          })
          ForEach(GENERAL_LEVELS, (level: string) => {
            LogMenuRow({
              title: logLevelLabel(level),
              selected: this.settings.saved.logLevel === level,
              reduceMotion: this.reduceMotion,
              interactive: !this.isUpdatingSettings,
              onPress: (): void => {
                this.dismissMore();
                if (this.settings.saved.logLevel !== level) {
                  this.updateLogSettings(this.settings.saved.captureLogs, level);
                }
              }
            })
          }, (level: string): string => level)
        }
        .width('100%')
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.submenuTransition)
      }
    }
    .width(LOG_MORE_MENU_WIDTH)
    .padding(8)
    .clip(true)
  }

  @Builder
  Actions() {
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle }) {
        AppGlyph({
          name: 'search',
          iconSize: HEADER_ICON_SIZE,
          iconColor: this.searchShown || this.query !== '' ? this.appStyle.palette.brand : $r('sys.color.icon_primary')
        })
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.logs_search'))
      .id('logs-search')
      .onClick((): void => {
        if (this.searchShown && this.query !== '') {
          this.query = '';
          this.refreshRows(false, true);
        }
        this.searchShown = !this.searchShown;
      })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(HEADER_ICON_SIZE)
          .fontColor([this.hasFilters ? this.appStyle.palette.brand : $r('sys.color.icon_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.logs_filter'))
      .id('logs-filter')
      .onClick((): void => { this.openFilterSheet(); })
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'more', iconSize: HEADER_ICON_SIZE })
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.diagnostics_more'))
      .id('logs-more')
      .onClick((): void => { this.openMore(); })
      .bindPopup(this.moreShown, {
        builder: this.MorePopup, placement: Placement.BottomRight, enableArrow: false, autoCancel: true,
        focusable: true, mask: true, targetSpace: 8, width: LOG_MORE_MENU_WIDTH, radius: 24,
        popupColor: this.appStyle.palette.cardBackground, systemMaterial: this.appStyle.sheetMaterial(),
        transition: this.reduceMotion ? TransitionEffect.IDENTITY : this.moreTransition,
        onStateChange: (event: PopupStateChangeParam): void => { if (!event.isVisible) { this.dismissMore(); } }
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  FilterSheet() {
    Column() {
      Row({ space: 12 }) {
        Text($r('app.string.logs_level_filter_title'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(COMPACT_TITLE_SIZE)
          .lineHeight(COMPACT_TITLE_LINE_HEIGHT)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppGlyph({ name: 'close', iconSize: 18 })
        }
        .attributeModifier(HEADER_ACTION)
        .backgroundColor(this.appStyle.palette.surfaceBlock)
        .accessibilityText($r('app.string.diagnostics_cancel'))
        .onClick((): void => { this.filtering = false; })
      }
      .width('100%')
      .constraintSize({ minHeight: SHEET_HEADER_HEIGHT })
      .padding({ left: 4 })

      Column({ space: 10 }) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(4) } }) {
          ForEach(LOG_FILTER_LEVELS, (level: string): void => {
            LogFilterChoice({
              level: level,
              count: this.levelCounts[level] ?? 0,
              chosen: this.draftLevels.includes(level),
              reduceMotion: this.reduceMotion,
              onPress: (): void => this.toggleDraftLevel(level)
            })
          }, (level: string): string => level)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(this.appStyle.palette.cardBackground)
      .borderRadius(22)
      .margin({ top: 4 })

      Row({ space: 12 }) {
        Button($r('app.string.theme_reset'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(500)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor(this.appStyle.palette.surfaceBlock)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .enabled(this.draftLevels.length > 0)
          .onClick((): void => { this.draftLevels = []; })
        Button($r('app.string.diagnostics_apply_filters'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.appStyle.palette.onBrand)
          .backgroundColor(this.appStyle.palette.brand)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(2)
          .onClick((): void => this.applyFilterSheet())
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
  }

  @Builder
  DetailSheet() {
    if (this.selected !== undefined) {
      LogRecordDetails({
        row: this.selected,
        onCopy: (): void => { this.copySelected(); },
        onCopyValue: (text: string): void => { this.copyText(text); }
      })
    }
  }

  @Builder
  LevelFilterChips() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.levelFilters, (level: string) => {
          Button({ type: ButtonType.Capsule }) {
            Row({ space: 6 }) {
              Text($r('app.string.logs_filter'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .flexShrink(0)
              Text(logLevelLabel(level))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(logLevelInk(level, this.appStyle.palette.brand))
                .maxLines(1)
                .flexShrink(1)
              AppGlyph({ name: 'close', iconSize: 12, iconColor: $r('sys.color.icon_secondary') })
                .flexShrink(0)
            }
            .padding({ left: 12, right: 10, top: 7, bottom: 7 })
          }
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(this.appStyle.palette.cardBackground)
          .border({ width: 0.5, color: this.appStyle.palette.divider })
          .accessibilityText(uiResourceText(this.getUIContext(), logLevelLabel(level)))
          .onClick((): void => this.toggleLevelFilter(level))
        }, (level: string): string => level)
      }
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 6, bottom: 8 })
    }
    .width('100%')
    .align(Alignment.Start)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  @Builder
  LogControls() {
    Column() {
      if (this.settings.saved.captureLogs && (this.searchShown || this.query !== '')) {
        Search({ value: this.query, placeholder: $r('app.string.logs_search') })
          .textFont({ size: 16, family: this.appStyle.fontFamily })
          .placeholderFont({ size: 16, family: this.appStyle.fontFamily })
          .accessibilityText($r('app.string.logs_search'))
          .margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 6, bottom: 6 })
          .onChange((text: string): void => {
            this.query = text;
            this.refreshRows(false, true);
          })
      }
      if (this.hasFilters) {
        this.LevelFilterChips()
      }
      if (this.settings.saved.captureLogs && this.recordCount > 0 &&
        (!this.conn.coreReady || this.streamState === 'failed' || this.streamState === 'retrying')) {
        Row({ space: 8 }) {
          Text($r('app.string.logs_disconnected'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
          if (this.conn.coreReady && (this.streamState === 'failed' || this.streamState === 'closed')) {
            Button($r('app.string.action_retry'))
              .fontFamily(this.appStyle.fontFamily)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .onClick((): void => { this.stop(); this.sync(); })
          }
        }
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    ScrollDestination({
      heading: (): void => this.Header(),
      actions: (): void => this.Actions(),
      pageShown: (_reason: VisibilityChangeReason): void => { this.shown = true; this.sync(); },
      pageHidden: (_reason: VisibilityChangeReason): void => { this.shown = false; this.sync(); }
    }) {
      ScrollControls({ controls: (): void => this.LogControls() }) {
        Stack({ alignContent: Alignment.Bottom }) {
          List({ scroller: this.viewport.scroller, space: 8 }) {
            LazyForEach(this.rows, (row: LogListRow) => {
              ListItem() {
                LogRecordItem({
                  row: row,
                  active: this.active,
                  onOpen: (): void => this.openDetails(row),
                  onFilterLevel: (level: string): void => this.toggleLevelFilter(level)
                })
              }
              .width('100%')
              .transition(this.animatedBatch === row.batch && !this.reduceMotion ?
                this.arrivalTransition : TransitionEffect.IDENTITY)
            }, (row: LogListRow): string => row.key)
          }
          .height('100%')
          .width('100%')
          .cachedCount(3, true)
          .contentStartOffset(8)
          .contentEndOffset(16)
          .clipContent(ContentClipMode.SAFE_AREA)
          .edgeEffect(EdgeEffect.Spring)
          .scrollBar(BarState.Auto)
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
          .maintainVisibleContentPosition(this.paused)
          .onAppear((): void => { this.viewport.bind(this.active); })
          .onDisAppear((): void => this.viewport.release())
          .onScrollIndex((first: number, last: number): void => {
            this.viewport.capture<LogListRow>(this.rows, first, last, (key: string): void => { this.history.window.anchor = key; });
          })
          .onDidScroll((): void => {
            this.viewport.captureCurrent<LogListRow>(this.rows, (key: string): void => { this.history.window.anchor = key; });
          })
          .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
            if (this.viewport.isUserAway(offset, source) && !this.paused) {
              this.viewport.pauseForUser();
              this.setPaused(true);
            }
          })

          if (this.shownCount === 0) {
            Scroll() {
              EmptyState({
                icon: $r('sys.symbol.doc_text'),
                title: this.emptyTitle(),
                hint: this.emptyHint(),
                actionLabel: this.emptyAction(),
                onAction: (): void => this.handleEmptyAction()
              })
            }
            .width('100%')
            .height('100%')
            .clipContent(ContentClipMode.SAFE_AREA)
            .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.emptyTransition)
          }

          if (this.paused && this.recordCount > 0) {
            Button({ type: ButtonType.Capsule }) {
              Row({ space: 6 }) {
                AppGlyph({ name: 'arrowUp', iconSize: 15, iconColor: this.appStyle.palette.onBrand })
                Text(this.pending > 0 ? $r('app.string.logs_view_new', this.pending) : $r('app.string.logs_latest'))
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.appStyle.palette.onBrand)
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
            .backgroundColor(this.appStyle.palette.brand)
            .shadow({ radius: 16, offsetY: 4, color: $r('app.color.dashboard_shadow') })
            .margin({ bottom: 20 })
            .id('logs-follow')
            .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.pillTransition)
            .onClick((): void => this.backToLatest())
          }
        }
        .layoutWeight(1)
        .width('100%')

        Column().bindSheet($$this.filtering, this.FilterSheet, {
          height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, showClose: false,
          systemMaterial: this.appStyle.sheetMaterial(),
          onWillAppear: (): void => { this.filterOpen = true; },
          onDisappear: (): void => { this.filterOpen = false; }
        })
        Column().bindSheet($$this.detailsShown, this.DetailSheet, {
          title: { title: $r('app.string.logs_detail') },
          detents: [SheetSize.MEDIUM, SheetSize.LARGE], systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onWillAppear: (): void => { this.detailOpen = true; },
          onDisappear: (): void => this.closeDetails()
        })
      }
    }
  }
}

@ComponentV2
struct LogMenuRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require title: ResourceStr;
  @Param subtitle: ResourceStr = '';
  @Param symbolIcon?: Resource = undefined;
  @Param endGlyph: string = '';
  @Param selected: boolean = false;
  @Param interactive: boolean = true;
  @Param reduceMotion: boolean = true;
  @Event onPress: () => void = () => {};

  build() {
    Button() {
      Row({ space: 10 }) {
        if (this.symbolIcon !== undefined) {
          SymbolGlyph(this.symbolIcon)
            .fontSize(20)
            .fontColor([this.interactive ? $r('sys.color.icon_primary') : $r('sys.color.icon_tertiary')])
        }
        Text(this.title)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontColor(this.interactive ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
        }
        if (this.endGlyph !== '') {
          AppGlyph({ name: this.endGlyph, iconSize: 16, iconColor: $r('sys.color.icon_secondary') })
        } else if (this.selected) {
          AppGlyph({ name: 'check', iconSize: 16, iconColor: this.appStyle.palette.brand })
        }
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(16)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(this.selected ? this.appStyle.palette.selectionTonal : Color.Transparent)
    .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
    .enabled(this.interactive)
    .accessibilityText(uiResourceText(this.getUIContext(), this.title))
    .accessibilitySelected(this.selected)
    .onClick((): void => { this.onPress(); })
  }
}

@ComponentV2
struct LogFilterChoice {
  @Param @Require level: string;
  @Param count: number = 0;
  @Param chosen: boolean = false;
  @Param reduceMotion: boolean = true;
  @Event onPress: () => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 6 }) {
        Stack() {
          AppGlyph({ name: 'check', iconSize: 10, iconColor: this.appStyle.palette.onBrand })
            .opacity(this.chosen ? 1 : 0)
            .scale({ x: this.chosen ? 1 : 0.55, y: this.chosen ? 1 : 0.55 })
            .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
        }
        .width(15)
        .height(15)
        .borderRadius(8)
        .border({ width: 1, color: this.chosen ? this.appStyle.palette.brand : $r('sys.color.icon_secondary') })
        .backgroundColor(this.chosen ? this.appStyle.palette.brand : Color.Transparent)
        .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
        Text(logLevelLabel(this.level))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.chosen ? logLevelInk(this.level, this.appStyle.palette.brand) : $r('sys.color.font_primary'))
        if (this.count > 0) {
          Text(`${this.count}`)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(16)
      .backgroundColor(this.chosen ? logLevelSurface(this.level, this.appStyle.palette.brandSoft,
        this.appStyle.palette.selectionTonal) : this.appStyle.palette.surfaceBlock)
      .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
    }
    .constraintSize({ minHeight: 52 })
    .padding({ top: 6, bottom: 6 })
    .backgroundColor(Color.Transparent)
    .accessibilityText(uiResourceText(this.getUIContext(), logLevelLabel(this.level)))
    .accessibilitySelected(this.chosen)
    .onClick((): void => this.onPress())
  }
}
