import { accessibility } from '@kit.AccessibilityKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { AppGlyph } from '../../components/AppGlyph';
import { DestinationTitle, DESTINATION_TITLE_OPTIONS } from '../../components/DestinationTitle';
import { EmptyState } from '../../components/EmptyState';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { DnsRecordDetails } from './RecordDetails';
import { RecordActionMenu, RecordFilterChips, RecordMenuOption, RecordMenuState } from './RecordFilters';
import { recordColumnTitle, recordErrorText, recordFacetText } from './RecordLabels';
import { DnsRecordList, RECORD_LIST_ANIMATION, recordListTransition } from './RecordList';
import { dnsRecords, DnsRecordsStore } from './RecordStores';

@ComponentV2
export struct DnsPage {
  @Param foreground: boolean = true;
  @Local store: DnsRecordsStore = dnsRecords;
  @Local conn: Connection = connection;
  @Local shown: boolean = false;
  @Local searchShown: boolean = false;
  @Local detailsShown: boolean = false;
  @Local preferencePending: boolean = false;
  @Local menuState: RecordMenuState = new RecordMenuState();
  @Local reduceMotion: boolean = true;
  private active: boolean = false;
  private generation: number = 0;
  private consumedNotice: number = 0;
  private actionOpen: boolean = false;
  private detailOpen: boolean = false;
  private runtimeBoot: string = '';
  private runtimeRevision: number = 0;
  private runtimeReady: boolean = false;
  private readonly reduceMotionChanged = (enabled: boolean): void => { this.reduceMotion = enabled; };
  private readonly emptyTransition: TransitionEffect = recordListTransition();

  aboutToAppear(): void {
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reduceMotionChanged);
  }

  aboutToDisappear(): void {
    accessibility.offAnimationReduceStateChange(this.reduceMotionChanged);
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
      this.store.select('');
      this.store.clearNotice();
    }
    if (entering) {
      this.store.setListAnimation((apply: () => void): void => {
        if (this.active && !this.reduceMotion) {
          this.getUIContext().animateTo(RECORD_LIST_ANIMATION, apply);
        } else { apply(); }
      });
    }
    if (!visible) {
      this.store.setListAnimation();
      this.store.setVisible(false);
    }
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
    if (notice === 'cacheCleared') { this.toast($r('app.string.diagnostics_cache_cleared')); }
    else if (notice === 'error') { this.toast(recordErrorText(error)); }
  }

  @Monitor('store.selectedId', 'store.version')
  syncSelection(): void {
    if (this.store.selected === undefined) { this.detailsShown = false; }
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
    if (!this.active || this.actionOpen || this.detailsShown || this.detailOpen) { return; }
    const generation = this.generation;
    this.actionOpen = true;
    this.menuState.open(title, options, (choice: string): void => {
      this.actionOpen = false;
      if (choice !== '' && this.isCurrent(generation)) { onSelect(choice); }
    });
  }

  private filtersMenu(): void {
    const fields: string[] = ['type', 'initiator', 'cache', 'rcode'];
    const choices: RecordMenuOption[] = fields.map<RecordMenuOption>((field: string): RecordMenuOption => {
      return { key: field, title: recordColumnTitle(field) };
    });
    this.menu($r('app.string.diagnostics_filters'), choices, (field: string): void => {
      const options: RecordMenuOption[] = this.store.facetOptions(field).map<RecordMenuOption>(
        (option: string): RecordMenuOption => { return { key: option, title: recordFacetText(field, option) }; });
      this.menu(recordColumnTitle(field), options, (option: string): void => { this.store.toggleFacet(field, option); });
    });
  }

  private openDetails(id: string): void {
    if (!this.active || this.actionOpen || this.detailsShown || this.detailOpen) { return; }
    this.store.select(id);
    this.detailsShown = this.store.selected !== undefined;
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

  private async clearCache(): Promise<void> {
    if (!this.active || !this.store.canAct || this.actionOpen || this.detailsShown || this.detailOpen) { return; }
    await this.store.clearCache();
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
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.tools_dns') })
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle }) {
        if (this.store.actionPending) {
          LoadingProgress().width(HEADER_ICON_SIZE).height(HEADER_ICON_SIZE)
        } else {
          AppGlyph({ name: 'sync', iconSize: HEADER_ICON_SIZE })
        }
      }
      .attributeModifier(HEADER_ACTION)
      .enabled(this.store.canAct)
      .accessibilityText($r('app.string.diagnostics_clear_cache'))
      .onClick((): void => { this.clearCache(); })
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'search', iconSize: HEADER_ICON_SIZE })
      }
      .attributeModifier(HEADER_ACTION)
      .accessibilityText($r('app.string.diagnostics_search'))
      .onClick((): void => { this.searchShown = !this.searchShown; })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(HEADER_ICON_SIZE)
          .fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .accessibilityText($r('app.string.diagnostics_filters'))
      .onClick((): void => { this.filtersMenu(); })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  DetailSheet() {
    DnsRecordDetails({ record: this.store.selected, interruptions: this.store.interruptions,
      dropped: this.store.dropped, evicted: this.store.evicted,
      onCopy: (text: string): void => { this.copyText(text); } })
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
        Stack() {
          DnsRecordList({ store: this.store, active: this.shown && this.foreground, reduceMotion: this.reduceMotion,
            onOpen: (id: string): void => { this.openDetails(id); } })
            .width('100%').height('100%')
          if (this.store.visibleRecords === 0) {
            Scroll() {
              EmptyState({ icon: $r('sys.symbol.connection'), title: this.emptyTitle, hint: this.emptyHint,
                actionLabel: this.emptyAction, onAction: (): void => { this.store.retry(); } })
            }
            .width('100%').height('100%')
            .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.emptyTransition)
          }
        }
        .layoutWeight(1).width('100%')
        if (!this.store.following && this.store.visibleRecords === 0) {
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
      }
      .width('100%').height('100%')
    }
    .title(this.HeaderTitle, DESTINATION_TITLE_OPTIONS)
    .menus(this.HeaderMenus)
    .backgroundColor($r('app.color.page_background'))
    .onShown((_reason: VisibilityChangeReason): void => { this.shown = true; this.syncLifecycle(); })
    .onHidden((_reason: VisibilityChangeReason): void => { this.shown = false; this.syncLifecycle(); })
  }
}
