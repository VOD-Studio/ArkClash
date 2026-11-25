import { ScrollControls } from '../../components/ScrollControls';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { FrameCallback, LengthMetrics, UIContext } from '@kit.ArkUI';
import { DiagnosticDnsRecord } from '../../client/Diagnostics';
import { AppGlyph } from '../../components/AppGlyph';
import { formatBytes, formatDateTime, formatSpeed } from '../../components/Format';
import { KeyedListSource } from '../../components/KeyedListSource';
import { uiResourceText } from '../../components/ResourceText';
import {
  ConnectionRecordView, RecordColumn, RecordSort, RecordView, connectionRule, diagnosticEndpoint,
  nextRecordSort, recordColumns, resizedTableColumns, tableColumnWidths
} from './RecordLogic';
import { recordColumnTitle, recordInitiatorText } from './RecordLabels';
import { ConnectionListRow, ConnectionRecordsStore, DnsListRow, DnsRecordsStore } from './RecordStores';

export const RECORD_LIST_ANIMATION: AnimateParam = { duration: 220, curve: Curve.EaseOut };
// 表格行较矮，标题、搜索框和表头背后最多还要绘制六行。
const TABLE_CACHE_ROWS = 6;

export function recordListTransition(offsetY: number = 0): TransitionEffect {
  const fade = TransitionEffect.opacity(0);
  const effect = offsetY === 0 ? fade : fade.combine(TransitionEffect.translate({ y: offsetY }));
  return effect.animation({ duration: 180, curve: Curve.EaseOut });
}

@ObservedV2
class RecordTableSlot {
  key: string;
  @Trace column: RecordColumn;
  @Trace extent: number;
  @Trace title: ResourceStr;
  @Trace sortGlyph: string;

  constructor(column: RecordColumn, extent: number, sortGlyph: string) {
    this.key = column.id;
    this.column = column;
    this.extent = extent;
    this.title = recordColumnTitle(column.id);
    this.sortGlyph = sortGlyph;
  }
}

@ObservedV2
class RecordResizeHandle {
  key: string;
  boundary: number;
  @Trace left: number;

  constructor(key: string, boundary: number, left: number) {
    this.key = key;
    this.boundary = boundary;
    this.left = left;
  }
}

@ObservedV2
class RecordTableCell {
  key: string;
  @Trace text: ResourceStr = '';
  @Trace extent: number = 0;
  @Trace numeric: boolean = false;
  @Trace proxy: string = '';
  @Trace color: ResourceColor = $r('sys.color.font_primary');

  constructor(key: string) { this.key = key; }
}

function recordCellsForSlots(previous: RecordTableCell[], slots: RecordTableSlot[]): RecordTableCell[] {
  if (previous.length === slots.length &&
    slots.every((slot: RecordTableSlot, index: number): boolean => slot.key === previous[index].key)) {
    return previous;
  }
  return slots.map<RecordTableCell>((slot: RecordTableSlot): RecordTableCell =>
    previous.find((cell: RecordTableCell): boolean => cell.key === slot.key) ?? new RecordTableCell(slot.key));
}

interface RecordProxyChip {
  key: string;
  name: string;
}

interface RecordViewportItem {
  key: string;
}

function recordWidthCopy(widths: Record<string, number>): Record<string, number> {
  const result: Record<string, number> = {};
  for (const key of Object.keys(widths)) { result[key] = widths[key]; }
  return result;
}

function recordSameWidths(left: Record<string, number>, right: Record<string, number>): boolean {
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length &&
    keys.every((key: string): boolean => left[key] === right[key]);
}

// 列宽只在尺寸、偏好或字体变化时计算；拖动草稿不触及持久层。
@ObservedV2
class RecordTableLayout {
  @Trace slots: RecordTableSlot[] = [];
  @Trace handles: RecordResizeHandle[] = [];
  @Trace rowExtent: number = 36;
  @Trace headerExtent: number = 32;
  @Trace tableMode: boolean = false;
  @Trace gutter: number = 16;
  @Trace revision: number = 0;
  private columns: RecordColumn[] = [];
  private extents: number[] = [];
  private headerWidths: Record<string, number> = {};
  private contentWidth: number = 0;
  private currentView: RecordView = 'connections';
  private saved: Record<string, number> = {};
  private draft: Record<string, number> = {};
  private sort: RecordSort = { column: '', direction: '' };
  private dragBoundary: number = -1;
  private dragWidths: number[] = [];
  private dragOverrides: Record<string, number> = {};
  private measuredScale: number = 0;
  private measuredLocale: string = '';
  private initialized: boolean = false;

  configure(ui: UIContext, view: RecordView, width: number,
    widths: Record<string, number>, sort: RecordSort): void {
    const rowExtent = ui.px2vp(ui.fp2px(20)) + 16;
    const locale = uiResourceText(ui, recordColumnTitle('protocol'));
    const metricsChanged = rowExtent !== this.measuredScale || locale !== this.measuredLocale;
    const geometryChanged = !this.initialized || metricsChanged || width !== this.contentWidth ||
      view !== this.currentView || !recordSameWidths(widths, this.saved);
    const sortChanged = sort.column !== this.sort.column || sort.direction !== this.sort.direction;
    if (!geometryChanged && !sortChanged) { return; }
    this.initialized = true;
    if (metricsChanged) {
      this.measuredScale = rowExtent;
      this.measuredLocale = locale;
      this.rowExtent = rowExtent;
      this.headerExtent = ui.px2vp(ui.fp2px(16)) + 16;
      const ids: string[] = ['time', 'target', 'protocol', 'rule', 'exit', 'traffic', 'download', 'upload',
        'downloadSpeed', 'uploadSpeed', 'duration', 'domain', 'type', 'initiator', 'result', 'elapsed', 'upstream'];
      const measured: Record<string, number> = {};
      for (const id of ids) {
        const size = ui.getMeasureUtils().measureTextSize({ textContent: uiResourceText(ui, recordColumnTitle(id)),
          fontSize: '16fp', fontWeight: FontWeight.Medium });
        // 排序 Symbol 的实际布局宽 12vp，间隔 4vp，左右内边距各 8vp。
        measured[id] = ui.px2vp(Number(size.width)) + 12 + 4 + 16;
      }
      this.headerWidths = measured;
    }
    this.sort = { column: sort.column, direction: sort.direction };
    if (geometryChanged) {
      this.dragBoundary = -1;
      this.contentWidth = width;
      this.currentView = view;
      this.saved = recordWidthCopy(widths);
      this.draft = recordWidthCopy(widths);
      this.tableMode = width >= 720;
      this.gutter = this.tableMode ? 8 : 16;
      this.columns = recordColumns(view, width, this.headerWidths);
      this.extents = tableColumnWidths(this.columns, Math.max(0, width - 16), this.draft);
    }
    this.publish(geometryChanged);
  }

  begin(boundary: number): void {
    if (boundary < 0 || boundary >= this.columns.length - 1) { return; }
    this.dragBoundary = boundary;
    this.dragWidths = this.extents.slice();
    this.dragOverrides = recordWidthCopy(this.draft);
  }

  resize(delta: number): void {
    if (this.dragBoundary < 0) { return; }
    this.draft = resizedTableColumns(this.columns, this.dragWidths, this.dragOverrides, this.dragBoundary, delta);
    this.extents = tableColumnWidths(this.columns, Math.max(0, this.contentWidth - 16), this.draft);
    this.publish(true);
  }

  finish(): Record<string, number> | undefined {
    if (this.dragBoundary < 0) { return undefined; }
    this.dragBoundary = -1;
    this.dragWidths = [];
    this.dragOverrides = {};
    return recordSameWidths(this.draft, this.saved) ? undefined : recordWidthCopy(this.draft);
  }

  cancel(): void {
    if (this.dragBoundary < 0) { return; }
    this.dragBoundary = -1;
    this.dragWidths = [];
    this.dragOverrides = {};
    this.draft = recordWidthCopy(this.saved);
    this.extents = tableColumnWidths(this.columns, Math.max(0, this.contentWidth - 16), this.draft);
    this.publish(true);
  }

  private publish(geometryChanged: boolean): void {
    const slots: RecordTableSlot[] = [];
    const handles: RecordResizeHandle[] = [];
    let right = 0;
    this.columns.forEach((column: RecordColumn, index: number): void => {
      const extent = this.extents[index] ?? 0;
      const glyph = this.sort.column === column.id && this.sort.direction !== '' ?
        (this.sort.direction === 'asc' ? 'chevronUp' : 'chevronDown') : 'sort';
      const slot = this.slots.find((item: RecordTableSlot): boolean => item.key === column.id) ??
        new RecordTableSlot(column, extent, glyph);
      slot.column = column;
      slot.extent = extent;
      slot.sortGlyph = glyph;
      slots.push(slot);
      right += extent;
      if (index < this.columns.length - 1 && column.resizable && this.columns[index + 1].resizable) {
        const handle = this.handles.find((item: RecordResizeHandle): boolean => item.key === column.id) ??
          new RecordResizeHandle(column.id, index, right - 6);
        handle.boundary = index;
        handle.left = right - 6;
        handles.push(handle);
      }
    });
    this.slots = slots;
    if (geometryChanged) {
      this.handles = handles;
      ++this.revision;
    }
  }
}

// 原生帧完成后恢复锚点，不用定时器猜测 LazyForEach 的布局时机。
class RecordAfterLayout extends FrameCallback {
  private action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onIdle(_timeLeftInNano: number): void { this.action(); }
}

class RecordListViewport {
  readonly scroller: Scroller = new Scroller();
  private bound: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private scheduled: boolean = false;
  private first: number = 0;
  private last: number = -1;
  private anchor: string = '';
  private anchorY: number = 0;
  private offset: number = 0;
  private skipPauseRestore: boolean = false;
  private topRequested: boolean = false;

  bind(active: boolean): void { this.bound = true; this.active = active; }
  release(): void { this.bound = false; this.scheduled = false; ++this.generation; }
  activate(active: boolean): void { this.active = active; this.scheduled = false; ++this.generation; }

  pauseForUser(): void {
    this.scheduled = false;
    this.skipPauseRestore = true;
    this.topRequested = false;
    ++this.generation;
  }

  captureCurrent<T extends RecordViewportItem>(source: KeyedListSource<T>, setAnchor: (key: string) => void): void {
    this.capture<T>(source, this.first, this.last, setAnchor);
  }

  isUserAway(delta: number, source: ScrollSource): boolean {
    if (!this.bound || !this.active) { return false; }
    const user = source === ScrollSource.DRAG || source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
      source === ScrollSource.SCROLL_BAR_FLING;
    if (!user || delta === 0) { return false; }
    this.scheduled = false;
    this.topRequested = false;
    ++this.generation;
    // 用原生事件记录偏移；排名更新与程序化滚动绝不触发暂停。
    this.offset = this.scroller.currentOffset().yOffset;
    return Math.max(0, this.offset + delta) > 1;
  }

  capture<T extends RecordViewportItem>(source: KeyedListSource<T>, first: number, last: number,
    setAnchor: (key: string) => void): void {
    if (!this.bound || !this.active) { return; }
    this.first = first;
    this.last = last;
    if (this.scheduled || first < 0 || last < first || source.totalCount() === 0) { return; }
    let index = first;
    while (index <= last && index < source.totalCount() && source.getData(index).key.startsWith('group:')) { ++index; }
    if (index < 0 || index > last || index >= source.totalCount()) { return; }
    const rect = this.scroller.getItemRect(index);
    if (rect.height <= 0) { return; }
    this.anchor = source.getData(index).key;
    this.anchorY = rect.y;
    this.offset = this.scroller.currentOffset().yOffset;
    setAnchor(this.anchor);
  }

  reconcile<T extends RecordViewportItem>(ui: UIContext, source: KeyedListSource<T>,
    following: boolean, anchor: string, forceTop: boolean = false): void {
    if (!this.bound || !this.active) { return; }
    if (this.skipPauseRestore && !following && !forceTop) { this.skipPauseRestore = false; return; }
    this.skipPauseRestore = false;
    this.topRequested = this.topRequested || forceTop;
    const generation = ++this.generation;
    this.scheduled = true;
    ui.postFrameCallback(new RecordAfterLayout((): void => {
      if (!this.bound || !this.active || generation !== this.generation) { return; }
      this.scheduled = false;
      if (source.totalCount() === 0) { return; }
      const resetTop = this.topRequested;
      this.topRequested = false;
      if (following || resetTop) {
        this.anchor = '';
        this.anchorY = 0;
        if (this.offset !== 0 || resetTop) {
          this.offset = 0;
          this.scroller.scrollToIndex(0, false, ScrollAlign.START);
        }
        return;
      }
      const key = anchor === '' ? this.anchor : anchor;
      let index = source.values().findIndex((row: T): boolean => row.key === key);
      if (index < 0) { index = Math.min(this.first, source.totalCount() - 1); }
      const retained = source.getData(index).key === this.anchor;
      const desiredY = retained ? this.anchorY : 0;
      if (index >= this.first && index <= this.last) {
        const rect = this.scroller.getItemRect(index);
        if (rect.height > 0 && Math.abs(rect.y - desiredY) < 0.5) { return; }
      }
      this.anchor = source.getData(index).key;
      this.anchorY = desiredY;
      this.scroller.scrollToIndex(index, false, ScrollAlign.START,
        { extraOffset: LengthMetrics.vp(-desiredY) });
    }));
  }
}

@ComponentV2
struct RecordTableHeader {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require layout: RecordTableLayout;
  @Param active: boolean = false;
  @Event onSort: (column: RecordColumn) => void = () => {};
  @Event onSave: (widths: Record<string, number>) => void = () => {};
  @Event onReset: () => void = () => {};

  private finishResize(): void {
    const widths = this.layout.finish();
    if (widths !== undefined && this.active) { this.onSave(widths); }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        ForEach(this.layout.slots, (slot: RecordTableSlot) => {
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Row({ space: 4 }) {
              Text(slot.title)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(16)
                .lineHeight('16fp')
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              AppGlyph({ name: slot.sortGlyph, iconSize: 12, iconColor: $r('sys.color.icon_secondary') })
            }
            .width('100%')
            .padding({ left: 8, right: 8 })
          }
          .width(slot.extent)
          .height(this.layout.headerExtent)
          .padding(0)
          .borderRadius(0)
          .accessibilityText(uiResourceText(this.getUIContext(), slot.title))
          .enabled(this.active)
          .onClick((): void => this.onSort(slot.column))
        }, (slot: RecordTableSlot): string => slot.key)
      }
      ForEach(this.layout.handles, (handle: RecordResizeHandle) => {
        Row() {
          Column()
            .width(1)
            .height('60%')
            .backgroundColor(this.appStyle.palette.divider)
        }
        .width(12)
        .height(this.layout.headerExtent)
        .justifyContent(FlexAlign.Center)
        .position({ x: handle.left, y: 0 })
        .enabled(this.active)
        .accessibilityText($r('app.string.diagnostics_resize_column'))
        .accessibilityDescription($r('app.string.diagnostics_reset_columns'))
        .gesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction((): void => { this.layout.cancel(); this.onReset(); }),
          PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
            .onActionStart((): void => this.layout.begin(handle.boundary))
            .onActionUpdate((event: GestureEvent): void => this.layout.resize(event.offsetX))
            .onActionEnd((): void => this.finishResize())
            .onActionCancel((): void => this.layout.cancel())
        ))
      }, (handle: RecordResizeHandle): string => handle.key)
    }
    .width('100%')
    .height(this.layout.headerExtent)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }
}

function recordClock(time: string): string {
  const milliseconds = Date.parse(time);
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toLocaleTimeString() : time;
}

function recordDuration(duration: number): string {
  const seconds = Math.floor(duration / 1000);
  if (seconds < 60) { return `${seconds} s`; }
  if (seconds < 3600) { return `${Math.floor(seconds / 60)} min ${seconds % 60} s`; }
  return `${Math.floor(seconds / 3600)} h ${Math.floor(seconds / 60) % 60} min`;
}

function recordConnectionCell(view: ConnectionRecordView, field: string): ResourceStr {
  const record = view.connection;
  switch (field) {
    case 'time': return recordClock(record.start);
    case 'target': return diagnosticEndpoint(record.metadata.host || record.metadata.destinationIP,
      record.metadata.destinationPort) || $r('app.string.diagnostics_unknown');
    case 'protocol': return record.metadata.network;
    case 'rule': return connectionRule(record);
    case 'exit': return record.chains[0] || $r('app.string.diagnostics_unknown');
    case 'traffic': return formatBytes(record.download + record.upload);
    case 'download': return formatBytes(record.download);
    case 'upload': return formatBytes(record.upload);
    case 'downloadSpeed': return formatSpeed(view.downloadSpeed);
    case 'uploadSpeed': return formatSpeed(view.uploadSpeed);
    case 'duration': return recordDuration(view.duration);
    default: return '';
  }
}

@ReusableV2
@ComponentV2
struct ConnectionRecordLine {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require row: ConnectionListRow;
  @Param @Require layout: RecordTableLayout;
  @Param live: boolean = false;
  @Param active: boolean = false;
  @Event onOpen: (id: string) => void = () => {};
  @Event onActions: (row: ConnectionRecordView) => void = () => {};
  @Event onProxy: (name: string) => void = () => {};
  @Event onGroup: (key: string) => void = () => {};
  @Local cells: RecordTableCell[] = [];
  @Local targetText: ResourceStr = '';
  @Local destinationText: string = '';
  @Local sourceText: string = '';
  @Local networkText: string = '';
  @Local ruleText: string = '';
  @Local clockText: string = '';
  @Local durationText: string = '';
  @Local downloadText: string = '';
  @Local uploadText: string = '';
  @Local chainChips: RecordProxyChip[] = [];
  @Local groupText: ResourceStr = '';
  private consumed: boolean = false;
  private presentedView?: ConnectionRecordView;
  private presentedChains?: string[];

  aboutToAppear(): void { this.present(); }
  aboutToReuse(): void {
    this.consumed = false;
    this.presentedView = undefined;
    this.presentedChains = undefined;
    this.present();
  }
  aboutToRecycle(): void { this.consumed = false; }

  @Monitor('row', 'row.record', 'row.group', 'layout.revision', 'live')
  updatePresentation(): void { this.present(); }

  private present(): void {
    const view = this.row.record;
    if (view === undefined) {
      this.groupText = this.row.group === '' ? $r('app.string.diagnostics_unknown') : this.row.group;
      this.cells = [];
      this.chainChips = [];
      this.presentedView = undefined;
      this.presentedChains = undefined;
      return;
    }
    const record = view.connection;
    const changed = view !== this.presentedView;
    if (changed) {
      const metadata = record.metadata;
      this.targetText = diagnosticEndpoint(metadata.host || metadata.destinationIP, metadata.destinationPort) ||
        $r('app.string.diagnostics_unknown');
      this.destinationText = metadata.host !== '' && metadata.destinationIP !== '' && metadata.host !== metadata.destinationIP ?
        diagnosticEndpoint(metadata.destinationIP, metadata.destinationPort) : '';
      this.sourceText = diagnosticEndpoint(metadata.sourceIP, metadata.sourcePort);
      this.networkText = metadata.network;
      this.ruleText = connectionRule(record);
      this.clockText = formatDateTime(Date.parse(record.start));
      this.durationText = recordDuration(view.duration);
      this.downloadText = formatSpeed(view.downloadSpeed);
      this.uploadText = formatSpeed(view.uploadSpeed);
      if (record.chains !== this.presentedChains) {
        this.chainChips = record.chains.slice().reverse().map<RecordProxyChip>((name: string, index: number): RecordProxyChip =>
          ({ key: `${index}:${name}`, name: name }));
        this.presentedChains = record.chains;
      }
      this.presentedView = view;
    }
    this.cells = recordCellsForSlots(this.cells, this.layout.slots);
    this.layout.slots.forEach((slot: RecordTableSlot, index: number): void => {
      const cell = this.cells[index];
      if (changed || cell.text === '') {
        cell.text = recordConnectionCell(view, slot.key);
        cell.proxy = slot.key === 'exit' ? (record.chains[0] ?? '') : '';
        cell.color = slot.key === 'downloadSpeed' ? this.appStyle.palette.brand :
          (slot.key === 'uploadSpeed' ? $r('app.color.upload') : $r('sys.color.font_primary'));
      }
      cell.extent = slot.extent;
      cell.numeric = slot.column.numeric;
    });
  }

  private open(): void {
    if (!this.active || this.consumed) { return; }
    if (this.row.record === undefined) { this.onGroup(this.row.key); }
    else { this.onOpen(this.row.record.connection.id); }
  }

  private actions(): void {
    if (!this.active || this.row.record === undefined) { return; }
    this.consumed = true;
    this.onActions(this.row.record);
  }

  @Builder
  private groupHeader() {
    Row({ space: 8 }) {
      AppGlyph({ name: 'chevronDown', iconSize: 16, iconColor: $r('sys.color.icon_secondary') })
        .rotate({ angle: this.row.expanded ? 0 : -90 })
      Text(this.groupText)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${this.row.groupCount}`)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .constraintSize({ minHeight: this.layout.rowExtent })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.appStyle.palette.surfaceBlock)
    .borderRadius(22)
    .accessibilityText(uiResourceText(this.getUIContext(), this.groupText))
    .accessibilityLevel('yes')
    .onClick((): void => this.open())
  }

  @Builder
  private tableRow() {
    Row() {
      ForEach(this.cells, (cell: RecordTableCell) => {
        if (cell.proxy !== '') {
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Text(cell.text)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(20)
              .lineHeight('20fp')
              .fontColor(this.appStyle.palette.brand)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width(cell.extent)
          .height(this.layout.rowExtent)
          .padding({ left: 8, right: 8 })
          .borderRadius(0)
          .onClick((): void => this.onProxy(cell.proxy))
        } else {
          Text(cell.text)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(20)
            .lineHeight('20fp')
            .fontColor(cell.color)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(cell.numeric ? TextAlign.End : TextAlign.Start)
            .width(cell.extent)
            .height(this.layout.rowExtent)
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        }
      }, (cell: RecordTableCell): string => cell.key)
    }
    .width('100%')
    .height(this.layout.rowExtent)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .onClick((): void => this.open())
    .gesture(LongPressGesture({ repeat: false }).onAction((): void => this.actions()))
  }

  @Builder
  private cardRow() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.targetText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.networkText !== '') {
          Text(this.networkText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor(this.appStyle.palette.brand)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.appStyle.palette.brandSoft)
            .borderRadius(10)
        }
      }
      .width('100%')
      if (this.destinationText !== '') {
        Text(this.destinationText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.ruleText !== '') {
        Text(this.ruleText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.chainChips.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.chainChips, (chip: RecordProxyChip) => {
            Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
              Text(chip.name)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontColor(this.appStyle.palette.brand)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .constraintSize({ maxWidth: '100%' })
            .backgroundColor(this.appStyle.palette.surfaceBlock)
            .borderRadius(10)
            .margin({ right: 6, bottom: 4 })
            .onClick((): void => this.onProxy(chip.name))
          }, (chip: RecordProxyChip): string => chip.key)
        }
        .width('100%')
      }
      if (this.sourceText !== '') {
        Row({ space: 6 }) {
          Text($r('app.string.diagnostics_source'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
          Text(this.sourceText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
      }
      if (this.live) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          Text(this.durationText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .accessibilityDescription($r('app.string.diagnostics_duration'))
          Row({ space: 4 }) {
            AppGlyph({ name: 'arrowDown', iconSize: 12, iconColor: this.appStyle.palette.brand })
            Text(this.downloadText)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(12)
              .fontColor(this.appStyle.palette.brand)
          }
          .accessibilityDescription($r('app.string.diagnostics_download_speed'))
          Row({ space: 4 }) {
            AppGlyph({ name: 'arrowUp', iconSize: 12, iconColor: $r('app.color.upload') })
            Text(this.uploadText)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(12)
              .fontColor($r('app.color.upload'))
          }
          .accessibilityDescription($r('app.string.diagnostics_upload_speed'))
        }
        .width('100%')
      } else {
        Text(this.clockText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .accessibilityDescription($r('app.string.diagnostics_time'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(22)
    .onClick((): void => this.open())
    .gesture(LongPressGesture({ repeat: false }).onAction((): void => this.actions()))
  }

  build() {
    Column() {
      if (this.row.record === undefined) {
        this.groupHeader()
      } else if (this.layout.tableMode) {
        this.tableRow()
      } else {
        this.cardRow()
      }
    }
    .width('100%')
    .enabled(this.active)
    .onTouch((event: TouchEvent): void => { if (event.type === TouchType.Down) { this.consumed = false; } })
  }
}

function recordDnsSummary(record: DiagnosticDnsRecord): string {
  return record.error || record.answers.join(', ') || record.rcode;
}

function recordDnsCell(record: DiagnosticDnsRecord, field: string): ResourceStr {
  switch (field) {
    case 'time': return recordClock(record.time);
    case 'domain': return record.domain;
    case 'type': return record.type;
    case 'initiator': return recordInitiatorText(record.initiator);
    case 'result': return recordDnsSummary(record);
    case 'elapsed': return `${record.delay} ms`;
    case 'upstream': return record.upstream || '—';
    default: return '';
  }
}

@ReusableV2
@ComponentV2
struct DnsRecordLine {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require row: DnsListRow;
  @Param @Require layout: RecordTableLayout;
  @Param active: boolean = false;
  @Event onOpen: (id: string) => void = () => {};
  @Local cells: RecordTableCell[] = [];
  @Local clockText: string = '';
  @Local resultText: string = '';
  @Local initiatorText: ResourceStr = '';
  @Local upstreamText: string = '';
  @Local elapsedText: string = '';
  @Local cacheText: ResourceStr = '';
  @Local resultColor: ResourceColor = $r('sys.color.font_primary');
  private presentedRecord?: DiagnosticDnsRecord;

  aboutToAppear(): void { this.present(); }
  aboutToReuse(): void { this.presentedRecord = undefined; this.present(); }

  @Monitor('row', 'layout.revision')
  updatePresentation(): void { this.present(); }

  private present(): void {
    const record = this.row.record;
    const changed = record !== this.presentedRecord;
    if (changed) {
      const failed = record.error !== '' || (record.rcode !== '' && record.rcode !== 'NOERROR');
      this.resultColor = failed ? $r('app.color.status_error') : $r('sys.color.font_primary');
      this.clockText = recordClock(record.time);
      this.resultText = recordDnsSummary(record);
      this.initiatorText = recordInitiatorText(record.initiator);
      this.cacheText = record.cached ? $r('app.string.diagnostics_cached') : $r('app.string.diagnostics_network_query');
      this.upstreamText = record.upstream || '—';
      this.elapsedText = `${record.delay} ms`;
      this.presentedRecord = record;
    }
    this.cells = recordCellsForSlots(this.cells, this.layout.slots);
    this.layout.slots.forEach((slot: RecordTableSlot, index: number): void => {
      const cell = this.cells[index];
      if (changed || cell.text === '') {
        cell.text = recordDnsCell(record, slot.key);
        cell.color = slot.key === 'result' ? this.resultColor : $r('sys.color.font_primary');
      }
      cell.extent = slot.extent;
      cell.numeric = slot.column.numeric;
    });
  }

  @Builder
  private tableRow() {
    Row() {
      ForEach(this.cells, (cell: RecordTableCell) => {
        Text(cell.text)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight('20fp')
          .fontColor(cell.color)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(cell.numeric ? TextAlign.End : TextAlign.Start)
          .width(cell.extent)
          .height(this.layout.rowExtent)
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      }, (cell: RecordTableCell): string => cell.key)
    }
    .width('100%')
    .height(this.layout.rowExtent)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }

  @Builder
  private cardRow() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.row.record.domain)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.row.record.type)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor(this.appStyle.palette.brand)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.appStyle.palette.brandSoft)
          .borderRadius(10)
      }
      .width('100%')
      Text(this.resultText)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .fontColor(this.resultColor)
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Flex({ wrap: FlexWrap.Wrap }) {
        Text(this.initiatorText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.appStyle.palette.surfaceBlock)
          .borderRadius(10)
          .margin({ right: 6, bottom: 4 })
        Text(this.cacheText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.appStyle.palette.surfaceBlock)
          .borderRadius(10)
          .margin({ right: 6, bottom: 4 })
        if (this.row.record.rcode !== '') {
          Text(this.row.record.rcode)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor(this.resultColor)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.appStyle.palette.surfaceBlock)
            .borderRadius(10)
            .margin({ bottom: 4 })
        }
      }
      .width('100%')
      Row({ space: 6 }) {
        Text($r('app.string.diagnostics_upstream'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
        Text(this.upstreamText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text(this.clockText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Text(this.elapsedText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(22)
  }

  build() {
    Column() {
      if (this.layout.tableMode) {
        this.tableRow()
      } else {
        this.cardRow()
      }
    }
    .width('100%')
    .enabled(this.active)
    .onClick((): void => { if (this.active) { this.onOpen(this.row.record.id); } })
  }
}

@ComponentV2
export struct ConnectionRecordList {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ConnectionRecordsStore;
  @Param active: boolean = false;
  @Param reduceMotion: boolean = true;
  @Event onOpen: (id: string) => void = () => {};
  @Event onActions: (row: ConnectionRecordView) => void = () => {};
  @Event onProxy: (name: string) => void = () => {};
  private layout: RecordTableLayout = new RecordTableLayout();
  private viewport: RecordListViewport = new RecordListViewport();
  private contentWidth: number = 0;
  private readonly itemTransition: TransitionEffect = recordListTransition(-8);
  @Local rowSpacing: number = 8;
  private feedChanged: boolean = false;

  aboutToAppear(): void { this.configure(); }
  aboutToDisappear(): void { this.viewport.release(); this.layout.cancel(); }

  @Monitor('active')
  visibilityChanged(): void {
    this.viewport.activate(this.active);
    this.layout.cancel();
    this.configure();
    if (this.active) { this.restore(); }
  }

  @Monitor('store.feed')
  switchFeed(): void { this.feedChanged = true; this.layout.cancel(); this.configure(); this.restore(); }

  @Monitor('store.version')
  recordsChanged(): void { this.configure(); this.restore(); }

  private configure(): void {
    const ui = this.getUIContext();
    this.layout.configure(ui, this.store.feed === 'live' ? 'connections' : 'requests',
      this.contentWidth, this.store.columnWidths, this.store.sort);
    this.rowSpacing = this.layout.tableMode ? 0 : 8;
  }

  private resizeContent(area: SizeOptions): void {
    const width = Number(area.width);
    if (!Number.isFinite(width) || width <= 0 || width === this.contentWidth) { return; }
    this.contentWidth = width;
    this.configure();
    this.restore();
  }

  private restore(): void {
    const forceTop = this.feedChanged;
    this.feedChanged = false;
    if (this.store.feed === 'live' && !forceTop) { return; }
    this.viewport.reconcile<ConnectionListRow>(this.getUIContext(), this.store.source,
      this.store.feed === 'recent' && this.store.following, this.store.anchorKey, forceTop);
  }

  private sortBy(column: RecordColumn): void {
    this.store.setSort(nextRecordSort(this.store.sort, column.id, column.descending));
  }

  private saveWidths(widths: Record<string, number>): void {
    this.store.saveColumnWidths(widths).catch((): void => {});
  }

  private toggleGroup(key: string): void {
    if (!this.active) { return; }
    if (this.active && !this.reduceMotion) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => this.store.toggleGroup(key));
    } else { this.store.toggleGroup(key); }
  }

  private backToLatest(): void {
    if (!this.active) { return; }
    this.store.setFollowing(true);
    this.viewport.reconcile<ConnectionListRow>(this.getUIContext(), this.store.source, true, '');
  }

  private recordVisible(first: number, last: number): void {
    if (this.store.feed !== 'recent') { return; }
    this.viewport.capture<ConnectionListRow>(this.store.source, first, last,
      (key: string): void => this.store.setAnchor(key));
  }

  @Builder
  TableHeader() {
    if (this.layout.tableMode && this.store.visibleRecords > 0) {
      Row() {
        RecordTableHeader({ layout: this.layout, active: this.active,
          onSort: (column: RecordColumn): void => this.sortBy(column),
          onSave: (widths: Record<string, number>): void => this.saveWidths(widths),
          onReset: (): void => this.saveWidths({}) })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
    }
  }

  build() {
    ScrollControls({ controls: (): void => this.TableHeader() }) {
      List({ scroller: this.viewport.scroller, space: this.rowSpacing }) {
        LazyForEach(this.store.source, (row: ConnectionListRow) => {
          ListItem() {
            ConnectionRecordLine({ row: row, layout: this.layout, live: this.store.feed === 'live', active: this.active,
              onOpen: (id: string): void => this.onOpen(id),
              onActions: (record: ConnectionRecordView): void => this.onActions(record),
              onProxy: (name: string): void => this.onProxy(name),
              onGroup: (key: string): void => this.toggleGroup(key) })
          }
          .width('100%')
          .transition(this.active && !this.reduceMotion ? this.itemTransition : TransitionEffect.IDENTITY)
        }, (row: ConnectionListRow): string => row.key)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: this.layout.gutter, right: this.layout.gutter })
      .cachedCount(this.layout.tableMode ? TABLE_CACHE_ROWS : 2, true)
      .contentStartOffset(8)
      .clipContent(ContentClipMode.SAFE_AREA)
      .maintainVisibleContentPosition(!this.store.following && this.store.feed === 'recent')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .onAppear((): void => { this.viewport.bind(this.active); this.restore(); })
      .onDisAppear((): void => this.viewport.release())
      .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => this.resizeContent(next))
      .onScrollIndex((first: number, last: number, _center: number): void => this.recordVisible(first, last))
      .onDidScroll((_offset: number, _state: ScrollState): void => {
        if (this.store.feed === 'recent') {
          this.viewport.captureCurrent<ConnectionListRow>(this.store.source, (key: string): void => this.store.setAnchor(key));
        }
      })
      .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
        if (this.store.feed === 'recent') {
          const away = this.viewport.isUserAway(offset, source);
          if (this.store.following && away) {
            this.viewport.pauseForUser();
            this.store.setFollowing(false);
          }
        }
      })
      if (this.store.feed === 'recent' && !this.store.following && this.store.visibleRecords > 0) {
        Button($r('app.string.diagnostics_latest'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontFamily(this.appStyle.fontFamily)
          .margin({ top: 8, bottom: 8 })
          .accessibilityDescription($r('app.string.diagnostics_paused'))
          .enabled(this.active)
          .onClick((): void => this.backToLatest())
      }
    }
  }
}

@ComponentV2
export struct DnsRecordList {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: DnsRecordsStore;
  @Param active: boolean = false;
  @Param reduceMotion: boolean = true;
  @Event onOpen: (id: string) => void = () => {};
  private layout: RecordTableLayout = new RecordTableLayout();
  private viewport: RecordListViewport = new RecordListViewport();
  private contentWidth: number = 0;
  private readonly itemTransition: TransitionEffect = recordListTransition(-8);
  @Local rowSpacing: number = 8;

  aboutToAppear(): void { this.configure(); }
  aboutToDisappear(): void { this.viewport.release(); this.layout.cancel(); }

  @Monitor('active')
  visibilityChanged(): void {
    this.viewport.activate(this.active);
    this.layout.cancel();
    this.configure();
    if (this.active) { this.restore(); }
  }

  @Monitor('store.version')
  recordsChanged(): void { this.configure(); this.restore(); }

  private configure(): void {
    const ui = this.getUIContext();
    this.layout.configure(ui, 'dns', this.contentWidth, this.store.columnWidths, this.store.sort);
    this.rowSpacing = this.layout.tableMode ? 0 : 8;
  }

  private resizeContent(area: SizeOptions): void {
    const width = Number(area.width);
    if (!Number.isFinite(width) || width <= 0 || width === this.contentWidth) { return; }
    this.contentWidth = width;
    this.configure();
    this.restore();
  }

  private restore(): void {
    this.viewport.reconcile<DnsListRow>(this.getUIContext(), this.store.source, this.store.following, this.store.anchorKey);
  }

  private sortBy(column: RecordColumn): void {
    this.store.setSort(nextRecordSort(this.store.sort, column.id, column.descending));
  }

  private saveWidths(widths: Record<string, number>): void {
    this.store.saveColumnWidths(widths).catch((): void => {});
  }

  private backToLatest(): void {
    if (!this.active) { return; }
    this.store.setFollowing(true);
    this.viewport.reconcile<DnsListRow>(this.getUIContext(), this.store.source, true, '');
  }

  @Builder
  TableHeader() {
    if (this.layout.tableMode && this.store.visibleRecords > 0) {
      Row() {
        RecordTableHeader({ layout: this.layout, active: this.active,
          onSort: (column: RecordColumn): void => this.sortBy(column),
          onSave: (widths: Record<string, number>): void => this.saveWidths(widths),
          onReset: (): void => this.saveWidths({}) })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
    }
  }

  build() {
    ScrollControls({ controls: (): void => this.TableHeader() }) {
      List({ scroller: this.viewport.scroller, space: this.rowSpacing }) {
        LazyForEach(this.store.source, (row: DnsListRow) => {
          ListItem() {
            DnsRecordLine({ row: row, layout: this.layout, active: this.active,
              onOpen: (id: string): void => this.onOpen(id) })
          }
          .width('100%')
          .transition(this.active && this.store.following && !this.reduceMotion ?
            this.itemTransition : TransitionEffect.IDENTITY)
        }, (row: DnsListRow): string => row.key)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: this.layout.gutter, right: this.layout.gutter })
      .cachedCount(this.layout.tableMode ? TABLE_CACHE_ROWS : 2, true)
      .contentStartOffset(8)
      .clipContent(ContentClipMode.SAFE_AREA)
      .maintainVisibleContentPosition(!this.store.following)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .onAppear((): void => { this.viewport.bind(this.active); this.restore(); })
      .onDisAppear((): void => this.viewport.release())
      .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => this.resizeContent(next))
      .onScrollIndex((first: number, last: number, _center: number): void => {
        this.viewport.capture<DnsListRow>(this.store.source, first, last, (key: string): void => this.store.setAnchor(key));
      })
      .onDidScroll((_offset: number, _state: ScrollState): void => {
        this.viewport.captureCurrent<DnsListRow>(this.store.source, (key: string): void => this.store.setAnchor(key));
      })
      .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
        const away = this.viewport.isUserAway(offset, source);
        if (this.store.following && away) {
          this.viewport.pauseForUser();
          this.store.setFollowing(false);
        }
      })
      if (!this.store.following && this.store.visibleRecords > 0) {
        Button($r('app.string.diagnostics_latest'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontFamily(this.appStyle.fontFamily)
          .margin({ top: 8, bottom: 8 })
          .accessibilityDescription($r('app.string.diagnostics_paused'))
          .enabled(this.active)
          .onClick((): void => this.backToLatest())
      }
    }
  }
}
