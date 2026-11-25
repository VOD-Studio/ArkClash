import { common } from '@kit.AbilityKit';
import { Connection, connection } from '../../client/Connection';
import { ControllerSocket, ControllerSocketState } from '../../client/ControllerSocket';
import { GeneralSettingsState, generalSettingsState } from '../../client/GeneralSettings';
import { exportLogs, LogFrame, LogRecord, logStream, LOG_LIMIT } from '../../client/Logs';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { GENERAL_LEVELS } from '../../shared/GeneralSettings';
import { logLevelLabel } from './LogLabels';

interface LogListRow {
  key: string;
  record: LogRecord;
}

@ComponentV2
export struct LogsPage {
  @Param @Require topInset: number;
  @Param foreground: boolean = false;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private settings: GeneralSettingsState = generalSettingsState;
  @Local private shown: boolean = false;
  @Local private streamState: ControllerSocketState = 'closed';
  @Local private query: string = '';
  @Local private levelFilter: string = '';
  @Local private filtering: boolean = false;
  @Local private paused: boolean = false;
  @Local private isExporting: boolean = false;
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
  private records: LogListRow[] = [];
  private frozen: LogListRow[] = [];
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
      this.stop();
      this.clear();
      return;
    }
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
    this.records = [];
    this.frozen = [];
    this.evicted = 0;
    this.recordCount = 0;
    this.paused = false;
    this.refreshRows();
  }

  private receive(frame: LogFrame): void {
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
    const incoming = frame.logs.map((record: LogRecord): LogListRow => ({ key: record.id, record: record }));
    this.records = frame.kind === 'delta' ? this.records.concat(incoming).slice(-LOG_LIMIT) : incoming;
    this.recordCount = this.records.length;
    if (!this.paused) { this.refreshRows(); }
  }

  private refreshRows(): void {
    const source = this.paused ? this.frozen : this.records;
    const words = this.query.toLowerCase().trim().split(new RegExp('\\s+'));
    const filtered = source.filter((row: LogListRow): boolean => {
      const record = row.record;
      if (this.levelFilter !== '' && record.level !== this.levelFilter) { return false; }
      const text = `${record.level} ${record.message}`.toLowerCase();
      return words.every((word: string): boolean => text.includes(word));
    }).reverse();
    this.rows.replace(filtered);
    this.shownCount = filtered.length;
  }

  private pauseOrResume(): void {
    this.paused = !this.paused;
    this.frozen = this.paused ? this.records.slice() : [];
    this.refreshRows();
  }

  private selectFilter(level: string): void {
    this.levelFilter = level;
    this.filtering = false;
    this.refreshRows();
  }

  private async saveFile(): Promise<void> {
    if (this.isExporting || this.records.length === 0) { return; }
    this.isExporting = true;
    const snapshot = this.records.map((row: LogListRow): LogRecord => row.record);
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
  Controls() {
    Row({ space: 8 }) {
      TextInput({ text: this.query, placeholder: $r('app.string.logs_search') })
        .layoutWeight(1).height(40).maxLength(256).onChange((text: string): void => {
          this.query = text;
          this.refreshRows();
        })
      Button(this.levelFilter === '' ? $r('app.string.logs_filter') : logLevelLabel(this.levelFilter))
        .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.filtering = true; })
      Button(this.paused ? $r('app.string.logs_resume') : $r('app.string.logs_pause'))
        .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.recordCount > 0 || this.paused)
        .onClick((): void => this.pauseOrResume())
    }.padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 8 })
  }

  build() {
    NavDestination() {
      Column() {
        if (this.settings.saved.captureLogs) { this.Controls() }
        if (this.gaps || this.evicted > 0) {
          Text(this.gaps ? $r('app.string.logs_gap') : $r('app.string.logs_evicted', this.evicted))
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
        }
        if (this.shownCount > 0) {
          List({ space: 6 }) {
            LazyForEach(this.rows, (row: LogListRow) => {
              ListItem() { LogRecordItem({ record: row.record }) }
            }, (row: LogListRow): string => row.key)
          }.layoutWeight(1).width('100%').cachedCount(3)
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 16 })
        } else {
          Column({ space: 12 }) {
            Text(this.emptyLabel()).fontSize(15).fontColor($r('sys.color.font_secondary'))
            if (this.streamState === 'failed') {
              Button($r('app.string.action_retry')).onClick((): void => { this.stop(); this.sync(); })
            }
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        }
      }.width('100%').height('100%')
        .bindSheet($$this.filtering, this.FilterSheet, { title: { title: $r('app.string.logs_filter') },
          height: SheetSize.MEDIUM, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
    }
    .title(this.Header, { systemMaterial: this.appStyle.regularMaterial() })
    .menus(this.Actions)
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
    .onShown((_reason: VisibilityChangeReason): void => { this.shown = true; this.sync(); })
    .onHidden((_reason: VisibilityChangeReason): void => { this.shown = false; this.sync(); })
  }
}

@ReusableV2
@ComponentV2
struct LogRecordItem {
  @Param @Require record: LogRecord;
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Column({ space: 5 }) {
      Row({ space: 8 }) {
        Text(logLevelLabel(this.record.level)).fontSize(13).fontWeight(FontWeight.Medium)
        Text(new Date(this.record.time).toLocaleTimeString()).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      Text(this.record.message).fontSize(15).copyOption(CopyOptions.LocalDevice).textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
    }.alignItems(HorizontalAlign.Start).width('100%').constraintSize({ minHeight: 60 }).padding(12)
      .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(16)
  }
}
