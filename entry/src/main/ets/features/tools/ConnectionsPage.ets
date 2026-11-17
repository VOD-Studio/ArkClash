import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { AppGlyph } from '../../components/AppGlyph';
import { EmptyState } from '../../components/EmptyState';
import { uiResourceText } from '../../components/ResourceText';
import { HEADER_ACTION, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { ConnectionRecordDetails } from './RecordDetails';
import { RecordActionMenu, RecordFilterChips, RecordMenuOption, RecordMenuState, recordGroupingText } from './RecordFilters';
import { ConnectionRecordView, diagnosticEndpoint, RecordGrouping, RequestFeed } from './RecordLogic';
import { recordColumnTitle, recordErrorText, recordFacetText } from './RecordLabels';
import { ConnectionRecordList } from './RecordList';
import { connectionRecords, ConnectionRecordsStore } from './RecordStores';

@ComponentV2
export struct ConnectionsPage {
  @Param foreground: boolean = true;
  @Local store: ConnectionRecordsStore = connectionRecords;
  @Local conn: Connection = connection;
  @Local shown: boolean = false;
  @Local searchShown: boolean = false;
  @Local detailsShown: boolean = false;
  @Local confirmShown: boolean = false;
  @Local preferencePending: boolean = false;
  @Local menuState: RecordMenuState = new RecordMenuState();
  private active: boolean = false;
  private generation: number = 0;
  private consumedNotice: number = 0;
  private actionOpen: boolean = false;
  private detailOpen: boolean = false;
  private confirmationOpen: boolean = false;
  private runtimeBoot: string = '';
  private runtimeRevision: number = 0;
  private runtimeReady: boolean = false;

  aboutToDisappear(): void {
    this.shown = false;
    this.syncLifecycle();
  }

  @Monitor('foreground', 'conn.state', 'conn.forward', 'conn.bootId', 'conn.configRevision',
    'conn.tunAttached', 'conn.listenersOpen', 'conn.sessionMode')
  syncLifecycle(): void {
    const visible = this.shown && this.foreground;
    const ready = this.conn.connected && !this.conn.busy;
    const changed = this.conn.bootId !== '' && this.conn.configRevision > 0 &&
      (this.runtimeBoot !== this.conn.bootId || this.runtimeRevision !== this.conn.configRevision);
    const entering = visible && !this.active;
    if (visible !== this.active || changed || ready !== this.runtimeReady) { ++this.generation; }
    this.active = visible;
    this.runtimeReady = ready;
    if (changed) { this.runtimeBoot = this.conn.bootId; this.runtimeRevision = this.conn.configRevision; }
    if (!visible || changed) {
      this.detailsShown = false;
      this.confirmShown = false;
      this.store.select('');
      this.store.clearNotice();
    }
    if (!visible) { this.store.setVisible(false); }
    this.store.setConnection(ready, this.conn.bootId, this.conn.configRevision);
    if (visible) { this.store.setVisible(true); }
    if (entering) { this.restore(this.generation); }
  }

  private isCurrent(generation: number): boolean {
    return this.active && generation === this.generation;
  }

  private async restore(generation: number): Promise<void> {
    try { await this.store.load(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    catch (_error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.diagnostics_preferences_failed')); }
    }
  }

  private toast(message: ResourceStr): void {
    if (this.active) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  @Monitor('store.noticeSerial')
  consumeNotice(): void {
    if (this.store.noticeSerial === this.consumedNotice) { return; }
    this.consumedNotice = this.store.noticeSerial;
    const notice = this.store.notice;
    const error = this.store.noticeError;
    this.store.clearNotice();
    if (!this.active) { return; }
    if (notice === 'closed') { this.toast($r('app.string.diagnostics_closed')); }
    else if (notice === 'error') { this.toast(recordErrorText(error)); }
  }

  @Monitor('store.selectedId', 'store.version')
  syncSelection(): void {
    if (this.store.selected === undefined) { this.detailsShown = false; }
  }

  @Computed
  get feedTitle(): ResourceStr {
    return this.store.feed === 'live' ? $r('app.string.diagnostics_live') : $r('app.string.diagnostics_recent');
  }

  @Computed
  get emptyTitle(): ResourceStr {
    if (!this.store.ready) { return $r('app.string.diagnostics_disconnected'); }
    if (this.store.error !== '') { return recordErrorText(this.store.error); }
    if (this.store.streamState === 'failed') { return $r('app.string.diagnostics_stream_failed'); }
    if (this.store.streamState !== 'open' || (!this.store.canAct && !this.store.actionPending)) {
      return $r('app.string.diagnostics_connecting');
    }
    return this.store.totalRecords > 0 ? $r('app.string.diagnostics_no_matches') :
      $r('app.string.diagnostics_no_records');
  }

  @Computed
  get emptyHint(): ResourceStr {
    if (!this.store.ready) { return $r('app.string.diagnostics_connect_hint'); }
    if (this.store.totalRecords > 0 && this.store.error === '' &&
      (this.store.canAct || this.store.actionPending)) {
      return $r('app.string.diagnostics_adjust_filters');
    }
    return $r('app.string.diagnostics_collect_hint');
  }

  @Computed
  get emptyAction(): ResourceStr {
    return this.store.ready && (this.store.error !== '' || this.store.streamState === 'failed') ?
      $r('app.string.diagnostics_retry') : '';
  }

  private menu(title: ResourceStr, options: RecordMenuOption[], onSelect: (choice: string) => void): void {
    if (!this.active || this.actionOpen || this.detailsShown || this.confirmShown ||
      this.detailOpen || this.confirmationOpen) { return; }
    const generation = this.generation;
    this.actionOpen = true;
    this.menuState.open(title, options, (choice: string): void => {
      this.actionOpen = false;
      if (choice !== '' && this.isCurrent(generation)) { onSelect(choice); }
    });
  }

  private selectFeed(): void {
    const choices: RecordMenuOption[] = [
      { key: 'live', title: $r('app.string.diagnostics_live') },
      { key: 'recent', title: $r('app.string.diagnostics_recent') }
    ];
    this.menu(this.feedTitle, choices, (choice: string): void => { this.store.setFeed(choice as RequestFeed); });
  }

  private moreActions(): void {
    const choices: RecordMenuOption[] = [
      { key: 'filters', title: $r('app.string.diagnostics_filters') },
      { key: 'grouping', title: $r('app.string.diagnostics_grouping') }
    ];
    this.menu($r('app.string.diagnostics_more'), choices, (choice: string): void => {
      if (choice === 'filters') { this.filterFields(); }
      else if (choice === 'grouping') { this.groupingMenu(); }
    });
  }

  private filterFields(): void {
    const fields: RecordMenuOption[] = [
      { key: 'network', title: recordColumnTitle('network') },
      { key: 'rule', title: recordColumnTitle('rule') }
    ];
    this.menu($r('app.string.diagnostics_filters'), fields, (field: string): void => {
      const choices: RecordMenuOption[] = this.store.facetOptions(field).map<RecordMenuOption>(
        (option: string): RecordMenuOption => { return { key: option, title: recordFacetText(field, option) }; });
      this.menu(recordColumnTitle(field), choices, (option: string): void => { this.store.toggleFacet(field, option); });
    });
  }

  private groupingMenu(): void {
    const groups: RecordGrouping[] = ['none', 'host', 'rule', 'exit'];
    const choices: RecordMenuOption[] = groups.map<RecordMenuOption>((group: RecordGrouping): RecordMenuOption => {
      return { key: group, title: recordGroupingText(group) };
    });
    this.menu($r('app.string.diagnostics_grouping'), choices,
      (choice: string): void => { this.store.setGrouping(choice as RecordGrouping); });
  }

  private openDetails(id: string): void {
    if (!this.active || this.actionOpen || this.detailsShown || this.confirmShown ||
      this.detailOpen || this.confirmationOpen) { return; }
    this.store.select(id);
    this.detailsShown = this.store.selected !== undefined;
  }

  private rowActions(view: ConnectionRecordView): void {
    const record = view.connection;
    const target = record.metadata.destinationIP === '' ? record.metadata.host : record.metadata.destinationIP;
    const endpoint = diagnosticEndpoint(target, record.metadata.destinationPort);
    const choices: RecordMenuOption[] = [];
    if (record.metadata.host !== '') {
      choices.push({ key: 'host', title: $r('app.string.diagnostics_copy_host') });
    }
    if (target !== '') { choices.push({ key: 'endpoint', title: $r('app.string.diagnostics_copy_endpoint') }); }
    if (this.store.feed === 'live' && this.store.canAct) {
      choices.push({ key: 'close', title: $r('app.string.diagnostics_close_one') });
    }
    if (choices.length === 0) { return; }
    this.menu($r('app.string.diagnostics_details'), choices, (choice: string): void => {
      if (choice === 'host') { this.copyText(record.metadata.host); }
      else if (choice === 'endpoint') { this.copyText(endpoint); }
      else if (choice === 'close') { this.store.closeOne(record.id); }
    });
  }

  private async copyText(text: string): Promise<void> {
    if (!this.active || text === '') { return; }
    const generation = this.generation;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      if (this.isCurrent(generation)) { this.toast($r('app.string.diagnostics_copied')); }
    } catch (_error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.diagnostics_copy_failed')); }
    }
  }

  private openCloseAll(): void {
    if (this.active && this.store.feed === 'live' && this.store.canAct && !this.detailsShown &&
      !this.confirmShown && !this.actionOpen && !this.detailOpen && !this.confirmationOpen) {
      this.confirmShown = true;
    }
  }

  private async closeAll(): Promise<void> {
    if (!this.active || !this.confirmShown || !this.store.canAct) { return; }
    const generation = this.generation;
    await this.store.closeAll();
    if (this.isCurrent(generation)) { this.confirmShown = false; }
  }

  private async retryPreferences(): Promise<void> {
    if (!this.active || this.preferencePending) { return; }
    const generation = this.generation;
    this.preferencePending = true;
    try { await this.store.retryPreferences(); }
    catch (_error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.diagnostics_preferences_failed')); }
    } finally { this.preferencePending = false; }
  }

  @Builder
  FeedTitle() {
    Button() {
      Row({ space: 6 }) {
        Text(this.feedTitle).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        AppGlyph({ name: 'chevronDown', iconSize: 16 })
      }
    }
    .height('100%')
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(Color.Transparent)
    .padding({ left: 0, right: 4, top: 8, bottom: 8 })
    .accessibilityText(uiResourceText(this.getUIContext(), this.feedTitle))
    .onClick((): void => { this.selectFeed(); })
  }

  @Builder
  HeaderMenus() {
    Row({ space: 8 }) {
      if (this.store.feed === 'live') {
        Button({ type: ButtonType.Circle }) {
          if (this.store.actionPending) {
            LoadingProgress().width(20).height(20)
          } else {
            AppGlyph({ name: 'close', iconSize: 20 })
          }
        }
        .attributeModifier(HEADER_ACTION)
        .enabled(this.store.canAct)
        .accessibilityText($r('app.string.diagnostics_close_all'))
        .onClick((): void => { this.openCloseAll(); })
      }
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'search', iconSize: 20 })
      }
      .attributeModifier(HEADER_ACTION)
      .accessibilityText($r('app.string.diagnostics_search'))
      .onClick((): void => { this.searchShown = !this.searchShown; })
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'more', iconSize: 20 })
      }
      .attributeModifier(HEADER_ACTION)
      .accessibilityText($r('app.string.diagnostics_more'))
      .onClick((): void => { this.moreActions(); })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  DetailSheet() {
    ConnectionRecordDetails({ record: this.store.selected, interruptions: this.store.interruptions,
      dropped: this.store.dropped, evicted: this.store.evicted,
      onCopy: (text: string): void => { this.copyText(text); } })
  }

  @Builder
  CloseAllSheet() {
    Scroll() {
    Column({ space: 20 }) {
      Text($r('app.string.diagnostics_close_all')).fontSize(22).fontWeight(FontWeight.Bold)
      Text($r('app.string.diagnostics_close_all_hint')).fontSize(16)
        .fontColor($r('sys.color.font_secondary'))
      Button() {
        Row({ space: 8 }) {
          if (this.store.actionPending) { LoadingProgress().width(20).height(20) }
          Text($r('app.string.diagnostics_close_all')).fontSize(16)
        }
      }
      .width('100%').enabled(this.store.canAct)
      .accessibilityText($r('app.string.diagnostics_close_all'))
      .onClick((): void => { this.closeAll(); })
      Button($r('app.string.diagnostics_cancel'))
        .width('100%').buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.store.actionPending)
        .onClick((): void => { this.confirmShown = false; })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 32 })
    }
    .width('100%').height('100%')
  }

  @Builder
  StatusContent() {
    if (this.store.visibleRecords > 0) {
      if (!this.store.ready) {
        Text($r('app.string.diagnostics_disconnected')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      } else if (this.store.error !== '' || this.store.streamState === 'failed') {
        Row({ space: 8 }) {
          Text(this.emptyTitle).fontSize(13).fontColor($r('app.color.status_error')).layoutWeight(1)
          Button($r('app.string.diagnostics_retry')).buttonStyle(ButtonStyleMode.NORMAL)
            .onClick((): void => { this.store.retry(); })
        }
      } else if (this.store.streamState !== 'open' || (!this.store.canAct && !this.store.actionPending)) {
        Text($r('app.string.diagnostics_connecting')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
    }
    if (this.store.interruptions > 0 || this.store.dropped > 0 || this.store.evicted > 0) {
      Text($r('app.string.diagnostics_gap', this.store.interruptions, this.store.dropped, this.store.evicted))
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
    }
    if (this.store.preferenceError !== '') {
      Row({ space: 8 }) {
        Text(recordErrorText(this.store.preferenceError)).fontSize(13)
          .fontColor($r('app.color.status_error')).layoutWeight(1)
        Button($r('app.string.diagnostics_retry_preferences')).buttonStyle(ButtonStyleMode.NORMAL)
          .enabled(!this.preferencePending).onClick((): void => { this.retryPreferences(); })
      }
    }
  }

  build() {
    NavDestination() {
      Column({ space: 8 }) {
        Column({ space: 8 }) {
          if (this.searchShown || this.store.query !== '') {
            Search({ value: this.store.query, placeholder: $r('app.string.diagnostics_search_hint') })
              .textFont({ size: 16 }).placeholderFont({ size: 16 })
              .accessibilityText($r('app.string.diagnostics_search'))
              .onChange((query: string): void => { this.store.setQuery(query); })
          }
          RecordFilterChips({ facets: this.store.facets,
            onRemove: (field: string, option: string): void => { this.store.toggleFacet(field, option); } })
          this.StatusContent()
        }
        .width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
        if (this.store.visibleRecords > 0) {
          ConnectionRecordList({ store: this.store, active: this.shown && this.foreground,
            onOpen: (id: string): void => { this.openDetails(id); },
            onActions: (record: ConnectionRecordView): void => { this.rowActions(record); },
            onProxy: (name: string): void => { if (this.active) { this.store.toggleFacet('proxy', name); } } })
            .layoutWeight(1).width('100%')
        } else {
          Scroll() {
            EmptyState({ icon: $r('sys.symbol.connection'), title: this.emptyTitle, hint: this.emptyHint,
              actionLabel: this.emptyAction, onAction: (): void => { this.store.retry(); } })
          }
          .layoutWeight(1).width('100%')
        }
        if (!this.store.following && this.store.feed === 'recent' && this.store.visibleRecords === 0) {
          Button($r('app.string.diagnostics_latest')).buttonStyle(ButtonStyleMode.NORMAL)
            .accessibilityDescription($r('app.string.diagnostics_paused'))
            .onClick((): void => { this.store.setFollowing(true); })
            .margin({ bottom: 8 })
        }
        RecordActionMenu({ menuState: this.menuState })
        Column().bindSheet($$this.detailsShown, this.DetailSheet, {
          height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: true,
          onWillAppear: (): void => { this.detailOpen = true; },
          onDisappear: (): void => { this.detailOpen = false; this.store.select(''); }
        })
        Column().bindSheet($$this.confirmShown, this.CloseAllSheet, {
          height: SheetSize.MEDIUM, systemMaterial: sheetMaterial(), showClose: false,
          onWillAppear: (): void => { this.confirmationOpen = true; },
          onDisappear: (): void => { this.confirmationOpen = false; },
          onWillDismiss: (action: DismissSheetAction): void => {
            if (!this.store.actionPending || !this.active || !this.store.ready) { action.dismiss(); }
          }
        })
      }
      .width('100%').height('100%')
    }
    .title(this.FeedTitle)
    .menus(this.HeaderMenus)
    .backgroundColor($r('app.color.page_background'))
    .onShown((_reason: VisibilityChangeReason): void => { this.shown = true; this.syncLifecycle(); })
    .onHidden((_reason: VisibilityChangeReason): void => { this.shown = false; this.syncLifecycle(); })
  }
}
