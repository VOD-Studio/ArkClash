import { ScrollControls } from '../../components/ScrollControls';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Connection, connection } from '../../client/Connection';
import { ControllerSocket, ControllerSocketState } from '../../client/ControllerSocket';
import { GeneralSettingsState, generalSettingsState } from '../../client/GeneralSettings';
import { exportLogs, LogFrame, LogRecord, logStream, LOG_LIMIT } from '../../client/Logs';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { ListRow } from '../../components/ListRow';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { GENERAL_LEVELS } from '../../shared/GeneralSettings';
import { logLevelLabel } from './LogLabels';
import { LogHistory, LogListRow } from './LogHistory';
import { RECORD_LIST_ANIMATION, recordListTransition, RecordListViewport } from './RecordList';
import { LogRecordDetails, LogRecordItem, logCopyText } from './LogRecordView';

@ComponentV2
export struct LogsPage {
  @Param foreground: boolean = false;
  @Param reduceMotion: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private settings: GeneralSettingsState = generalSettingsState;
  @Local private shown: boolean = false;
  @Local private streamState: ControllerSocketState = 'closed';
  @Local private query: string = '';
  @Local private levelFilter: string = '';
  @Local private filtering: boolean = false;
  @Local private paused: boolean = false;
  @Local private pending: number = 0;
  @Local private animatedBatch: number = 0;
  @Local private isExporting: boolean = false;
  @Local private detailsShown: boolean = false;
  @Local private selected?: LogListRow;
  @Local private shownCount: number = 0;
  @Local private recordCount: number = 0;
  @Local private gaps: boolean = false;
  @Local private evicted: number = 0;
  private readonly filters: string[] = [''].concat(GENERAL_LEVELS.filter((level: string): boolean => level !== 'silent'));
  private socket?: ControllerSocket;
  private boot: string = '';
  private revision: number = 0;
  private session: string = '';
  private seq: number = 0;
  private readonly history: LogHistory = new LogHistory(LOG_LIMIT);
  private readonly viewport: RecordListViewport = new RecordListViewport();
  private readonly arrivalTransition: TransitionEffect = recordListTransition(-8);
  private detailOpen: boolean = false;
  private followingBeforeDetail: boolean = false;
  private readonly rows: KeyedListSource<LogListRow> = new KeyedListSource<LogListRow>();

  aboutToAppear(): void {
    if (!this.settings.loaded) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settings.load(context).catch((): void => {});
    }
  }

  @Monitor('foreground', 'conn.coreReady', 'conn.bootId', 'conn.configRevision', 'settings.saved')
  sync(): void {
    if (!this.shown || !this.foreground || !this.settings.saved.captureLogs) {
      if (this.socket !== undefined && this.settings.saved.captureLogs) { this.gaps = true; }
      if (!this.settings.saved.captureLogs) { this.gaps = false; }
      this.viewport.activate(false);
      this.stop();
      this.clear();
      return;
    }
    this.viewport.activate(true);
    if (!this.conn.coreReady || this.conn.bootId === '' || this.conn.configRevision === 0) {
      if (this.socket !== undefined) { this.gaps = true; }
      this.stop();
      return;
    }
    if (this.boot !== this.conn.bootId || this.revision !== this.conn.configRevision) {
      if (this.boot !== '') { this.gaps = true; }
      this.stop();
      this.clear();
      this.boot = this.conn.bootId;
      this.revision = this.conn.configRevision;
    }
    if (this.socket === undefined) {
      this.socket = logStream(this.boot, this.revision,
        (frame: LogFrame): void => this.receive(frame),
        (state: ControllerSocketState): void => {
          this.streamState = state;
          if (state === 'retrying' || state === 'failed') { this.gaps = true; }
        });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.socket.start(context.filesDir);
    }
  }

  aboutToDisappear(): void {
    this.shown = false;
    this.sync();
  }

  private stop(): void {
    this.socket?.stop();
    this.socket = undefined;
    this.session = '';
    this.seq = 0;
  }

  private clear(): void {
    this.followingBeforeDetail = false;
    this.selected = undefined;
    this.detailsShown = false;
    this.history.clear();
    this.evicted = 0;
    this.recordCount = 0;
    this.paused = false;
    this.refreshRows();
  }

  private receive(frame: LogFrame): void {
    const newSession = frame.kind === 'snapshot' && frame.seq === 1 && frame.sessionId !== this.session;
    if (frame.kind === 'snapshot' && frame.seq === 1) {
      if (this.session !== '' && this.session !== frame.sessionId) { this.gaps = true; }
      this.session = frame.sessionId;
    } else if (frame.sessionId !== this.session || frame.seq !== this.seq + 1) {
      this.gaps = true;
      this.socket?.fail('log_sequence');
      return;
    }
    this.seq = frame.seq;
    this.evicted = frame.evicted;
    if (frame.dropped > 0) { this.gaps = true; }
    this.history.receive(frame.logs, frame.kind, newSession);
    this.recordCount = this.history.window.latestCount;
    this.refreshRows(frame.kind === 'delta', newSession);
  }

  private refreshRows(delta: boolean = false, forceTop: boolean = false): void {
    const filtered = this.history.filter(this.query, this.levelFilter);
    const animate = delta && this.shown && this.foreground && !this.reduceMotion && !this.paused;
    this.animatedBatch = animate ? this.history.batch : 0;
    this.rows.replace(filtered, animate ? (apply: () => void): void => {
      this.getUIContext().animateTo(RECORD_LIST_ANIMATION, apply);
    } : undefined);
    this.shownCount = filtered.length;
    this.pending = this.history.pending;
    this.viewport.reconcile<LogListRow>(this.getUIContext(), this.rows, !this.paused, this.history.window.anchor, forceTop);
  }

  private pauseOrResume(): void {
    this.paused = !this.paused;
    this.history.setFollowing(!this.paused);
    this.refreshRows(false, !this.paused);
  }

  private selectFilter(level: string): void {
    this.levelFilter = level;
    this.filtering = false;
    this.refreshRows(false, true);
  }

  private openDetails(row: LogListRow): void {
    if (!this.shown || !this.foreground || this.filtering || this.detailsShown || this.detailOpen) { return; }
    this.followingBeforeDetail = !this.paused;
    if (!this.paused) { this.pauseOrResume(); }
    this.selected = row;
    this.detailsShown = true;
  }

  private closeDetails(): void {
    this.detailOpen = false;
    this.selected = undefined;
    if (this.followingBeforeDetail && this.paused && this.pending === 0 && this.shown && this.foreground) {
      this.pauseOrResume();
    }
    this.followingBeforeDetail = false;
  }

  private async copySelected(): Promise<void> {
    const row = this.selected;
    if (row === undefined || !this.shown || !this.foreground) { return; }
    let message = $r('app.string.diagnostics_copied');
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        logCopyText(row.record)));
    } catch (_error) { message = $r('app.string.diagnostics_copy_failed'); }
    if (this.selected === row && this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private async saveFile(): Promise<void> {
    if (this.isExporting || this.recordCount === 0) { return; }
    this.isExporting = true;
    const snapshot = this.history.window.latest().map((row: LogListRow): LogRecord => row.record);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await exportLogs(context, snapshot) && this.shown) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.logs_exported') });
      }
    } catch (_error) {
      if (this.shown) { this.getUIContext().getPromptAction().showToast({ message: $r('app.string.logs_export_failed') }); }
    } finally { this.isExporting = false; }
  }

  private emptyLabel(): Resource {
    if (!this.settings.saved.captureLogs) { return $r('app.string.logs_capture_off'); }
    if (this.settings.saved.logLevel === 'silent') { return $r('app.string.logs_silent'); }
    if (!this.conn.coreReady || this.streamState === 'failed' || this.streamState === 'retrying') {
      return $r('app.string.logs_disconnected');
    }
    if (this.streamState === 'connecting') { return $r('app.string.logs_connecting'); }
    if (this.recordCount > 0) { return $r('app.string.logs_no_matches'); }
    return $r('app.string.logs_empty');
  }

  @Builder
  Header() { DestinationTitle({ titleText: $r('app.string.tools_logs') }) }

  @Builder
  Actions() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.arrow_down_to_line')).fontSize(HEADER_ICON_SIZE)
      }
      .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.logs_export')).id('logs-export')
      .enabled(!this.isExporting && this.recordCount > 0).onClick((): void => { this.saveFile(); })
    }.height('100%').padding({ right: PAGE_GUTTER })
  }

  @Builder
  FilterSheet() {
    Column() {
      ForEach(this.filters, (level: string): void => {
        ListRow({ title: level === '' ? $r('app.string.logs_all_levels') : logLevelLabel(level), chevron: false,
          trailingIcon: level === this.levelFilter ? $r('sys.symbol.checkmark') : undefined,
          onTap: (): void => this.selectFilter(level) })
      }, (level: string): string => level === '' ? 'all' : level)
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
  }

  @Builder
  DetailSheet() {
    if (this.selected !== undefined) {
      LogRecordDetails({ record: this.selected.record, onCopy: (): void => { this.copySelected(); } })
    }
  }

  @Builder
  Controls() {
    Row({ space: 8 }) {
      TextInput({ text: this.query, placeholder: $r('app.string.logs_search') })
        .layoutWeight(1).height(40).maxLength(256).onChange((text: string): void => {
          this.query = text;
          this.refreshRows(false, true);
        })
      Button(this.levelFilter === '' ? $r('app.string.logs_filter') : logLevelLabel(this.levelFilter))
        .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.filtering = true; })
      Button(this.paused && this.pending > 0 ? $r('app.string.logs_view_new', this.pending) :
        this.paused ? $r('app.string.logs_resume') : $r('app.string.logs_pause'))
        .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.recordCount > 0 || this.paused)
        .id('logs-follow')
        .onClick((): void => this.pauseOrResume())
    }.padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 8 })
  }

  @Builder
  LogControls() {
    if (this.settings.saved.captureLogs) { this.Controls() }
    if (this.settings.saved.captureLogs && this.recordCount > 0 &&
      (!this.conn.coreReady || this.streamState === 'failed' || this.streamState === 'retrying' || this.streamState === 'closed')) {
      Row({ space: 8 }) {
        Text($r('app.string.logs_disconnected')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        if (this.conn.coreReady && (this.streamState === 'failed' || this.streamState === 'closed')) {
          Button($r('app.string.action_retry')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.stop(); this.sync(); })
        }
      }.padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
    } else if (this.gaps || this.evicted > 0) {
      Text(this.gaps ? $r('app.string.logs_gap') : $r('app.string.logs_evicted', this.evicted))
        .fontSize(13).fontColor($r('sys.color.font_secondary'))
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.Header(),
      actions: (): void => this.Actions(),
      pageShown: (_reason: VisibilityChangeReason): void => { this.shown = true; this.sync(); },
      pageHidden: (_reason: VisibilityChangeReason): void => { this.shown = false; this.sync(); }
    }) {
      ScrollControls({ controls: (): void => this.LogControls() }) {
        Stack() {
          List({ scroller: this.viewport.scroller, space: 6 }) {
            LazyForEach(this.rows, (row: LogListRow) => {
              ListItem() {
                LogRecordItem({ record: row.record, onOpen: (): void => this.openDetails(row) })
              }
                .transition(this.animatedBatch === row.batch && !this.reduceMotion ?
                  this.arrivalTransition : TransitionEffect.IDENTITY)
            }, (row: LogListRow): string => row.key)
          }.height('100%').width('100%').cachedCount(3, true)
            .clipContent(ContentClipMode.SAFE_AREA)
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 16 })
            .maintainVisibleContentPosition(this.paused)
            .onAppear((): void => { this.viewport.bind(this.shown && this.foreground); })
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
                this.pauseOrResume();
              }
            })
          if (this.shownCount === 0) {
            Column({ space: 12 }) {
              Text(this.emptyLabel()).fontSize(15).fontColor($r('sys.color.font_secondary'))
              if (this.streamState === 'failed' && this.recordCount === 0) {
                Button($r('app.string.action_retry')).onClick((): void => { this.stop(); this.sync(); })
              }
            }.width('100%').justifyContent(FlexAlign.Center)
          }
        }.layoutWeight(1).width('100%')
        Column().bindSheet($$this.filtering, this.FilterSheet, { title: { title: $r('app.string.logs_filter') },
          height: SheetSize.MEDIUM, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
        Column().bindSheet($$this.detailsShown, this.DetailSheet, { title: { title: $r('app.string.logs_detail') },
          detents: [SheetSize.MEDIUM, SheetSize.LARGE], systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onWillAppear: (): void => { this.detailOpen = true; }, onDisappear: (): void => this.closeDetails() })
      }
    }
  }
}
