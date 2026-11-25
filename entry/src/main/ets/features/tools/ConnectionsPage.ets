import { ScrollControls } from '../../components/ScrollControls';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { accessibility } from '@kit.AccessibilityKit';
import { common } from '@kit.AbilityKit';
import { UIUtils } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { AppGlyph } from '../../components/AppGlyph';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { EmptyState } from '../../components/EmptyState';
import { uiResourceText } from '../../components/ResourceText';
import {
  COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE,
  PAGE_GUTTER
} from '../../components/Theme';
import { ConnectionRecordDetails } from './RecordDetails';
import { RecordActionMenu, RecordFilterChips, RecordMenuOption, RecordMenuState, recordGroupingText } from './RecordFilters';
import { ConnectionRecordView, diagnosticEndpoint, RecordGrouping, RequestFeed } from './RecordLogic';
import { recordColumnTitle, recordErrorText, recordFacetText } from './RecordLabels';
import { ConnectionRecordList, RECORD_LIST_ANIMATION, recordListTransition } from './RecordList';
import { connectionRecords, ConnectionRecordsStore } from './RecordStores';

const CONNECTION_GROUPINGS: RecordGrouping[] = ['none', 'host', 'rule', 'exit'];
const MORE_MENU_WIDTH = 200;
type ConnectionMenuLevel = 'root' | 'filters' | 'grouping';

interface ConnectionFilterSection {
  field: string;
  options: string[];
}

function menuLevelTransition(offsetX: number): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: offsetX }))
      .animation({ delay: 60, duration: 150, curve: Curve.EaseOut }),
    TransitionEffect.opacity(0).animation({ duration: 60, curve: Curve.EaseOut })
  );
}

@ComponentV2
export struct ConnectionsPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param foreground: boolean = true;
  @Param initialFeed: RequestFeed | undefined = undefined;
  @Local store: ConnectionRecordsStore = connectionRecords;
  @Local conn: Connection = connection;
  @Local shown: boolean = false;
  @Local searchShown: boolean = false;
  @Local detailsShown: boolean = false;
  @Local confirmShown: boolean = false;
  @Local preferencePending: boolean = false;
  @Local menuState: RecordMenuState = new RecordMenuState();
  @Local moreShown: boolean = false;
  @Local moreLevel: ConnectionMenuLevel = 'root';
  @Local networkOptions: string[] = [];
  @Local ruleOptions: string[] = [];
  @Local reduceMotion: boolean = true;
  private active: boolean = false;
  private initialFeedApplied: boolean = false;
  private generation: number = 0;
  private consumedNotice: number = 0;
  private actionOpen: boolean = false;
  private detailOpen: boolean = false;
  private confirmationOpen: boolean = false;
  private runtimeBoot: string = '';
  private runtimeRevision: number = 0;
  private runtimeReady: boolean = false;
  private readonly reduceMotionChanged = (enabled: boolean): void => { this.reduceMotion = enabled; };
  private readonly emptyTransition: TransitionEffect = recordListTransition();
  private readonly moreTransition: TransitionEffect = TransitionEffect.asymmetric(
    TransitionEffect.scale({ x: 0.86, y: 0.86, centerX: '90%', centerY: 0 })
      .combine(TransitionEffect.opacity(0)).animation({ duration: 210, curve: Curve.EaseOut }),
    TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '90%', centerY: 0 })
      .combine(TransitionEffect.opacity(0)).animation({ duration: 140, curve: Curve.EaseIn })
  );
  private readonly rootTransition: TransitionEffect = menuLevelTransition(-16);
  private readonly submenuTransition: TransitionEffect = menuLevelTransition(16);

  aboutToAppear(): void {
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reduceMotionChanged);
  }

  aboutToDisappear(): void {
    accessibility.offAnimationReduceStateChange(this.reduceMotionChanged);
    this.shown = false;
    this.syncLifecycle();
  }

  @Monitor('foreground', 'conn.coreReady', 'conn.hostState', 'conn.bootId', 'conn.configRevision',
    'conn.state', 'conn.forward', 'conn.vpnCreated', 'conn.tunAttached', 'conn.listenersOpen')
  syncLifecycle(): void {
    const visible = this.shown && this.foreground;
    const ready = this.conn.coreReady && this.conn.hostState === 'running';
    const forwardingReady = this.conn.connected && !this.conn.busy;
    const changed = this.runtimeBoot !== this.conn.bootId || this.runtimeRevision !== this.conn.configRevision;
    const entering = visible && !this.active;
    if (visible !== this.active || changed || ready !== this.runtimeReady) { ++this.generation; }
    this.active = visible;
    this.runtimeReady = ready;
    if (changed) { this.runtimeBoot = this.conn.bootId; this.runtimeRevision = this.conn.configRevision; }
    if (!forwardingReady) { this.confirmShown = false; }
    if (!visible || changed) {
      this.dismissMore();
      this.detailsShown = false;
      this.confirmShown = false;
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
    this.store.setConnection(ready, this.conn.bootId, this.conn.configRevision, forwardingReady);
    if (visible) { this.store.setVisible(true); }
    if (entering) { this.restore(this.generation); }
  }

  private isCurrent(generation: number): boolean {
    return this.active && generation === this.generation;
  }

  private async restore(generation: number): Promise<void> {
    const initial = !this.initialFeedApplied ? this.initialFeed : undefined;
    if (initial !== undefined) { this.initialFeedApplied = true; }
    try {
      await this.store.load(this.getUIContext().getHostContext() as common.UIAbilityContext,
        initial, this.initialFeedApplied);
    }
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
    if (!this.store.synced) {
      return $r('app.string.diagnostics_connecting');
    }
    return this.store.totalRecords > 0 ? $r('app.string.diagnostics_no_matches') :
      $r('app.string.diagnostics_no_records');
  }

  @Computed
  get emptyHint(): ResourceStr {
    if (!this.store.ready) { return $r('app.string.diagnostics_connect_hint'); }
    if (this.store.totalRecords > 0 && this.store.error === '' && this.store.synced) {
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
    if (!this.active || this.moreShown || this.actionOpen || this.detailsShown || this.confirmShown ||
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

  private openMore(): void {
    if (!this.active || this.moreShown || this.actionOpen || this.detailsShown || this.confirmShown ||
      this.detailOpen || this.confirmationOpen) { return; }
    this.moreLevel = 'root';
    this.moreShown = true;
    this.syncMoreFilters();
  }

  private dismissMore(): void {
    if (!this.moreShown) { return; }
    this.moreShown = false;
  }

  private changeMoreLevel(from: ConnectionMenuLevel, to: ConnectionMenuLevel): void {
    if (!this.active || !this.moreShown || this.moreLevel !== from) { return; }
    if (this.reduceMotion) {
      this.moreLevel = to;
      return;
    }
    this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseOut }, (): void => {
      UIUtils.applySync<void>((): void => { this.moreLevel = to; });
    });
  }

  @Monitor('store.version')
  syncMoreFilters(): void {
    if (!this.moreShown) { return; }
    const networks = this.store.facetOptions('network');
    const rules = this.store.facetOptions('rule');
    if (networks.length !== this.networkOptions.length ||
      networks.some((option: string, index: number): boolean => option !== this.networkOptions[index])) {
      this.networkOptions = networks;
    }
    if (rules.length !== this.ruleOptions.length ||
      rules.some((option: string, index: number): boolean => option !== this.ruleOptions[index])) {
      this.ruleOptions = rules;
    }
    if (this.moreLevel === 'filters' && networks.length === 0 && rules.length === 0) {
      this.moreLevel = 'root';
    }
  }

  private selectGrouping(grouping: RecordGrouping): void {
    if (!this.active || !this.moreShown || this.moreLevel !== 'grouping') { return; }
    this.dismissMore();
    this.store.setGrouping(grouping);
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
    DestinationTitle({ titleText: this.feedTitle, selectable: true, onSelect: (): void => { this.selectFeed(); } })
  }

  @Builder
  FilterSection($$: ConnectionFilterSection) {
    if ($$.options.length > 0) {
      Text(recordColumnTitle($$.field === 'network' ? 'protocol' : $$.field))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(13).fontWeight(600).fontColor($r('sys.color.font_secondary'))
        .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 4 })
      ForEach($$.options, (option: string) => {
        ConnectionMenuRow({
          title: recordFacetText($$.field, option),
          selected: this.store.facets[$$.field]?.includes(option) ?? false,
          reduceMotion: this.reduceMotion,
          onPress: (): void => {
            if (this.active && this.moreShown && this.moreLevel === 'filters') { this.store.toggleFacet($$.field, option); }
          }
        })
      }, (option: string): string => option)
    }
  }

  @Builder
  MorePopup() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.moreLevel === 'root') {
        Column() {
          if (this.networkOptions.length > 0 || this.ruleOptions.length > 0) {
            ConnectionMenuRow({ title: $r('app.string.diagnostics_filters'), glyph: 'rules', endGlyph: 'chevronForward',
              onPress: (): void => this.changeMoreLevel('root', 'filters') })
          }
          ConnectionMenuRow({ title: $r('app.string.diagnostics_grouping'), glyph: 'layers', endGlyph: 'chevronForward',
            onPress: (): void => this.changeMoreLevel('root', 'grouping') })
        }
        .width('100%').transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.rootTransition)
      } else {
        Column() {
          if (this.moreLevel === 'filters') {
            ConnectionMenuRow({ title: $r('app.string.diagnostics_filters'), glyph: 'rules', endGlyph: 'chevronUp',
              onPress: (): void => this.changeMoreLevel('filters', 'root') })
            Scroll() {
              Column() {
                this.FilterSection({ field: 'network', options: this.networkOptions })
                this.FilterSection({ field: 'rule', options: this.ruleOptions })
              }
              .width('100%')
            }
            .width('100%').constraintSize({ maxHeight: 320 }).scrollBar(BarState.Auto)
          } else {
            ConnectionMenuRow({ title: $r('app.string.diagnostics_grouping'), glyph: 'layers', endGlyph: 'chevronUp',
              onPress: (): void => this.changeMoreLevel('grouping', 'root') })
            ForEach(CONNECTION_GROUPINGS, (grouping: RecordGrouping) => {
              ConnectionMenuRow({ title: recordGroupingText(grouping), selected: this.store.grouping === grouping,
                reduceMotion: this.reduceMotion, onPress: (): void => { this.selectGrouping(grouping); } })
            }, (grouping: RecordGrouping): string => grouping)
          }
        }
        .width('100%').transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.submenuTransition)
      }
    }
    .width(MORE_MENU_WIDTH).padding(8).clip(true)
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.store.feed === 'live') {
        Button({ type: ButtonType.Circle }) {
          if (this.store.actionPending) {
            LoadingProgress().width(HEADER_ICON_SIZE).height(HEADER_ICON_SIZE)
          } else {
            AppGlyph({ name: 'close', iconSize: HEADER_ICON_SIZE })
          }
        }
        .attributeModifier(HEADER_ACTION)
        .systemMaterial(this.appStyle.headerMaterial())
        .enabled(this.store.canAct)
        .accessibilityText($r('app.string.diagnostics_close_all'))
        .onClick((): void => { this.openCloseAll(); })
      }
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'search', iconSize: HEADER_ICON_SIZE })
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.diagnostics_search'))
      .onClick((): void => { this.searchShown = !this.searchShown; })
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'more', iconSize: HEADER_ICON_SIZE })
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.diagnostics_more'))
      .onClick((): void => { this.openMore(); })
      .bindPopup(this.moreShown, {
        builder: this.MorePopup, placement: Placement.BottomRight, enableArrow: false, autoCancel: true,
        focusable: true, mask: true, targetSpace: 8, width: MORE_MENU_WIDTH, radius: 24,
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
  DetailSheet() {
    ConnectionRecordDetails({ record: this.store.selected,
      onCopy: (text: string): void => { this.copyText(text); } })
  }

  @Builder
  CloseAllSheet() {
    Scroll() {
    Column({ space: 20 }) {
      Text($r('app.string.diagnostics_close_all')).fontFamily(this.appStyle.fontFamily).fontSize(COMPACT_TITLE_SIZE)
        .lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
      Text($r('app.string.diagnostics_close_all_hint')).fontFamily(this.appStyle.fontFamily).fontSize(16)
        .fontColor($r('sys.color.font_secondary'))
      Button() {
        Row({ space: 8 }) {
          if (this.store.actionPending) { LoadingProgress().width(20).height(20) }
          Text($r('app.string.diagnostics_close_all')).fontFamily(this.appStyle.fontFamily).fontSize(16)
        }
      }
      .width('100%').enabled(this.store.canAct)
      .accessibilityText($r('app.string.diagnostics_close_all'))
      .onClick((): void => { this.closeAll(); })
      Button($r('app.string.diagnostics_cancel'))
        .fontFamily(this.appStyle.fontFamily)
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
        Text($r('app.string.diagnostics_disconnected')).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
      } else if (this.store.error !== '' || this.store.streamState === 'failed') {
        Row({ space: 8 }) {
          Text(this.emptyTitle).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('app.color.status_error')).layoutWeight(1)
          Button($r('app.string.diagnostics_retry')).fontFamily(this.appStyle.fontFamily).buttonStyle(ButtonStyleMode.NORMAL)
            .onClick((): void => { this.store.retry(); })
        }
      } else if (!this.store.synced) {
        Text($r('app.string.diagnostics_connecting')).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
    }
    if (this.store.interruptions > 0 || this.store.dropped > 0 || this.store.evicted > 0) {
      Text($r('app.string.diagnostics_gap', this.store.interruptions, this.store.dropped, this.store.evicted))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
    }
    if (this.store.preferenceError !== '') {
      Row({ space: 8 }) {
        Text(recordErrorText(this.store.preferenceError)).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($r('app.color.status_error')).layoutWeight(1)
        Button($r('app.string.diagnostics_retry_preferences')).fontFamily(this.appStyle.fontFamily).buttonStyle(ButtonStyleMode.NORMAL)
          .enabled(!this.preferencePending).onClick((): void => { this.retryPreferences(); })
      }
    }
  }

  @Builder
  FilterControls() {
    Column({ space: 8 }) {
      if (this.searchShown || this.store.query !== '') {
        Search({ value: this.store.query, placeholder: $r('app.string.diagnostics_search_hint') })
          .textFont({ size: 16, family: this.appStyle.fontFamily }).placeholderFont({ size: 16, family: this.appStyle.fontFamily })
          .accessibilityText($r('app.string.diagnostics_search'))
          .onChange((query: string): void => { this.store.setQuery(query); })
      }
      RecordFilterChips({ facets: this.store.facets,
        onRemove: (field: string, option: string): void => { this.store.toggleFacet(field, option); } })
      this.StatusContent()
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  build() {
    ScrollDestination({
      heading: (): void => this.FeedTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (_reason: VisibilityChangeReason): void => { this.shown = true; this.syncLifecycle(); },
      pageHidden: (_reason: VisibilityChangeReason): void => { this.shown = false; this.syncLifecycle(); }
    }) {
      ScrollControls({ controls: (): void => this.FilterControls() }) {
        Stack() {
          ConnectionRecordList({ store: this.store, active: this.shown && this.foreground,
            reduceMotion: this.reduceMotion,
            onOpen: (id: string): void => { this.openDetails(id); },
            onActions: (record: ConnectionRecordView): void => { this.rowActions(record); },
            onProxy: (name: string): void => { if (this.active) { this.store.toggleFacet('proxy', name); } } })
            .width('100%').height('100%')
          if (this.store.visibleRecords === 0) {
            Scroll() {
              EmptyState({ icon: $r('sys.symbol.connection'), title: this.emptyTitle, hint: this.emptyHint,
                actionLabel: this.emptyAction, onAction: (): void => { this.store.retry(); } })
            }
            .width('100%').height('100%')
            .clipContent(ContentClipMode.SAFE_AREA)
            .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.emptyTransition)
          }
        }
        .layoutWeight(1).width('100%')
        if (!this.store.following && this.store.feed === 'recent' && this.store.visibleRecords === 0) {
          Button($r('app.string.diagnostics_latest')).fontFamily(this.appStyle.fontFamily).buttonStyle(ButtonStyleMode.NORMAL)
            .accessibilityDescription($r('app.string.diagnostics_paused'))
            .onClick((): void => { this.store.setFollowing(true); })
            .margin({ bottom: 8 })
        }
        RecordActionMenu({ menuState: this.menuState })
        Column().bindSheet($$this.detailsShown, this.DetailSheet, {
          height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          title: { title: this.store.feed === 'live' ? $r('app.string.diagnostics_connection_details') :
            $r('app.string.diagnostics_request_details') },
          onWillAppear: (): void => { this.detailOpen = true; },
          onDisappear: (): void => { this.detailOpen = false; this.store.select(''); }
        })
        Column().bindSheet($$this.confirmShown, this.CloseAllSheet, {
          height: SheetSize.MEDIUM, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
          onWillAppear: (): void => { this.confirmationOpen = true; },
          onDisappear: (): void => { this.confirmationOpen = false; },
          onWillDismiss: (action: DismissSheetAction): void => {
            if (!this.store.actionPending || !this.active || !this.store.ready) { action.dismiss(); }
          }
        })
      }
    }
  }
}

@ComponentV2
struct ConnectionMenuRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require title: ResourceStr;
  @Param glyph: string = '';
  @Param endGlyph: string = '';
  @Param selected: boolean = false;
  @Param reduceMotion: boolean = true;
  @Event onPress: () => void = () => {};

  build() {
    Button() {
      Row({ space: 8 }) {
        if (this.glyph !== '') { AppGlyph({ name: this.glyph, iconSize: 20 }) }
        Text(this.title).fontFamily(this.appStyle.fontFamily).fontSize(15).fontColor($r('sys.color.font_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.endGlyph !== '') {
          AppGlyph({ name: this.endGlyph, iconSize: 16 })
        } else {
          AppGlyph({ name: 'check', iconSize: 16, iconColor: this.appStyle.palette.brand })
            .opacity(this.selected ? 1 : 0).scale({ x: this.selected ? 1 : 0.65, y: this.selected ? 1 : 0.65 })
            .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
        }
      }
      .width('100%')
    }
    .width('100%').constraintSize({ minHeight: 44 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(16)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(this.selected ? this.appStyle.palette.selectionTonal : Color.Transparent)
    .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
    .accessibilityText(uiResourceText(this.getUIContext(), this.title)).accessibilitySelected(this.selected)
    .onClick((): void => { this.onPress(); })
  }
}
