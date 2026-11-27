import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { CapsuleSegmentButtonV2, ColorMetrics, SegmentButtonV2Items, TextModifier } from '@kit.ArkUI';
import { connection, Connection } from '../../client/Connection';
import { peekVpnNetworkSettings, readVpnNetworkSettings, saveVpnNetworkSettings } from '../../client/VpnNetworkSettings';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { EmptyState } from '../../components/EmptyState';
import { KeyedListSource } from '../../components/KeyedListSource';
import { ScrollControls } from '../../components/ScrollControls';
import { ScrollDestination } from '../../components/ScrollDestination';
import { CARD_RADIUS, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import {
  MAX_VPN_EXCLUDED_APPS, MAX_VPN_TRUSTED_APPS, VPN_APP_ACCESS_MODES, VpnAppAccessMode, VpnNetworkSettings
} from '../../shared/VpnNetwork';
import { ACCESS_APP_CATEGORIES, AccessAppCategory } from './AccessControlCatalog';
import { AccessControlDraft, AccessControlRowItem } from './AccessControlLogic';

interface AccessHeaderActionOption {
  icon: Resource;
  label: Resource;
  available: boolean;
  highlight?: boolean;
  invoke: () => void;
}

@ComponentV2
export struct AccessControlPage {
  @Param foreground: boolean = true;
  @Param reduceMotion: boolean = true;
  @Event onClose: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private loading: boolean = peekVpnNetworkSettings() === undefined;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private activeMode: VpnAppAccessMode = 'off';
  @Local private selectedBundles: string[] = [];
  @Local private excludedCount: number = 0;
  @Local private trustedCount: number = 0;
  @Local private dirty: boolean = false;
  @Local private query: string = '';
  @Local private searchShown: boolean = false;
  @Local private activeCategory: AccessAppCategory = 'all';
  @Local private visibleCount: number = 0;
  @Local private firstKey: string = '';
  @Local private lastKey: string = '';
  @Local private importShown: boolean = false;
  @Local private importDraft: string = '';
  @Local private importReplace: boolean = false;
  @Local private importIssue: ResourceStr = '';
  @Local private leaveShown: boolean = false;
  private draft: AccessControlDraft = new AccessControlDraft(peekVpnNetworkSettings() ?? new VpnNetworkSettings());
  private rows: KeyedListSource<AccessControlRowItem> = new KeyedListSource<AccessControlRowItem>();
  private visibleBundles: string[] = [];
  private shown: boolean = false;
  private approvedClose: boolean = false;
  private chinese: boolean = true;

  aboutToAppear(): void {
    this.chinese = i18n.System.getSystemLanguage().startsWith('zh');
    const cached = peekVpnNetworkSettings();
    if (cached !== undefined) {
      this.applyLoaded(cached);
    }
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private applyLoaded(settings: VpnNetworkSettings): void {
    this.draft = new AccessControlDraft(settings);
    this.syncFromDraft();
  }

  private syncFromDraft(): void {
    this.activeMode = this.draft.mode;
    this.selectedBundles = this.draft.activeList().slice();
    this.excludedCount = this.draft.excluded.length;
    this.trustedCount = this.draft.trusted.length;
    this.dirty = this.draft.isDirty();
    this.refreshRows();
  }

  private refreshRows(): void {
    const items = this.draft.rows(this.query, this.activeCategory, this.chinese);
    this.visibleCount = items.length;
    this.visibleBundles = items.map((item: AccessControlRowItem): string => item.bundleName);
    this.firstKey = items[0]?.key ?? '';
    this.lastKey = items[items.length - 1]?.key ?? '';
    this.rows.replace(items);
  }

  private async load(): Promise<void> {
    if (this.dirty) {
      return;
    }
    const silent = peekVpnNetworkSettings() !== undefined;
    if (!silent) {
      this.loading = true;
    }
    try {
      const loaded = await readVpnNetworkSettings(this.context());
      if (!this.dirty) {
        this.applyLoaded(loaded);
      }
      this.loadFailed = false;
    } catch (_error) {
      if (!silent) {
        this.loadFailed = true;
      }
    } finally {
      this.loading = false;
    }
  }

  private editable(): boolean {
    return !this.loading && !this.loadFailed && !this.saving;
  }

  private errorText(code: string): ResourceStr {
    switch (code) {
      case 'empty_trusted_apps': return $r('app.string.access_control_empty_trusted');
      case 'too_many_apps':
        return $r('app.string.network_app_limit',
          this.activeMode === 'trusted' ? MAX_VPN_TRUSTED_APPS : MAX_VPN_EXCLUDED_APPS);
      case 'own_bundle_only': return $r('app.string.access_control_own_only');
      case 'invalid_bundle_name': return $r('app.string.access_control_import_empty');
      default: return $r('app.string.network_save_failed');
    }
  }

  private chooseMode(index: number): void {
    const next = VPN_APP_ACCESS_MODES[index];
    if (!this.editable() || next === undefined || next === this.activeMode) {
      return;
    }
    this.draft.setMode(next);
    if (next === 'off') {
      this.searchShown = false;
      this.query = '';
      this.activeCategory = 'all';
    }
    this.syncFromDraft();
  }

  private toggleBundle(bundleName: string): void {
    if (!this.editable() || this.activeMode === 'off') {
      return;
    }
    const error = this.draft.toggle(bundleName);
    if (error !== '') {
      this.toast(this.errorText(error));
      return;
    }
    this.syncFromDraft();
  }

  private toggleVisible(): void {
    if (!this.editable() || this.activeMode === 'off') {
      return;
    }
    const error = this.draft.toggleVisible(this.visibleBundles);
    if (error !== '') {
      this.toast(this.errorText(error));
      return;
    }
    this.syncFromDraft();
  }

  private clearActive(): void {
    if (!this.editable() || this.activeMode === 'off') {
      return;
    }
    this.draft.clearActive();
    this.syncFromDraft();
  }

  private toggleSearch(): void {
    this.searchShown = !this.searchShown;
    if (!this.searchShown && this.query !== '') {
      this.query = '';
      this.refreshRows();
    }
  }

  private openImport(): void {
    if (!this.editable() || this.activeMode === 'off') {
      return;
    }
    this.importDraft = '';
    this.importReplace = false;
    this.importIssue = '';
    this.importShown = true;
  }

  private async pasteFromClipboard(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data.getPrimaryText();
      if (text.trim() === '') {
        this.importIssue = $r('app.string.access_control_clipboard_empty');
        return;
      }
      this.importDraft = this.importDraft.trim() === '' ? text : `${this.importDraft}\n${text}`;
      this.importIssue = '';
    } catch (_error) {
      this.importIssue = $r('app.string.access_control_clipboard_failed');
    }
  }

  private confirmImport(): void {
    if (!this.editable() || this.activeMode === 'off') {
      return;
    }
    const outcome = this.draft.applyImport(this.importDraft, this.context().applicationInfo.name, this.importReplace);
    if (!outcome.ok) {
      this.importIssue = this.errorText(outcome.error);
      return;
    }
    this.importShown = false;
    this.syncFromDraft();
    if (outcome.skippedOwn) {
      this.toast($r('app.string.access_control_import_own_skipped', outcome.addedCount));
    } else if (outcome.invalidCount > 0) {
      this.toast($r('app.string.access_control_import_partial', outcome.addedCount, outcome.invalidCount));
    } else {
      this.toast($r('app.string.access_control_import_done', outcome.addedCount));
    }
  }

  private async exportToClipboard(): Promise<void> {
    const text = this.draft.exportText();
    if (text === '') {
      this.toast($r('app.string.access_control_export_empty'));
      return;
    }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.toast($r('app.string.access_control_export_done', this.selectedBundles.length));
    } catch (_error) {
      this.toast($r('app.string.access_control_export_failed'));
    }
  }

  private async save(closeAfter: boolean): Promise<void> {
    if (!this.editable()) {
      return;
    }
    const issue = this.draft.validationError();
    if (issue !== '') {
      this.leaveShown = false;
      this.toast(this.errorText(issue));
      return;
    }
    const effectiveChanged = this.draft.effectiveChanged();
    const next = this.draft.toSettings();
    this.saving = true;
    try {
      await saveVpnNetworkSettings(this.context(), next);
      this.applyLoaded(next);
      this.leaveShown = false;
      this.toast(this.conn.connected && effectiveChanged ?
        $r('app.string.network_reconnect') : $r('app.string.network_saved'));
      if (closeAfter) {
        this.approvedClose = true;
        this.onClose();
      }
    } catch (error) {
      this.leaveShown = false;
      this.toast(this.errorText((error as Error).message));
    } finally {
      this.saving = false;
    }
  }

  private handleBack(): boolean {
    if (this.saving) {
      return true;
    }
    if (this.searchShown) {
      this.toggleSearch();
      return true;
    }
    if (!this.approvedClose && this.dirty) {
      this.leaveShown = true;
      return true;
    }
    return false;
  }

  private categoryLabel(category: AccessAppCategory): Resource {
    switch (category) {
      case 'browser': return $r('app.string.access_control_cat_browser');
      case 'container': return $r('app.string.access_control_cat_container');
      case 'social': return $r('app.string.access_control_cat_social');
      case 'finance': return $r('app.string.access_control_cat_finance');
      case 'shopping': return $r('app.string.access_control_cat_shopping');
      case 'life': return $r('app.string.access_control_cat_life');
      case 'media': return $r('app.string.access_control_cat_media');
      default: return $r('app.string.access_control_cat_all');
    }
  }

  private allVisibleSelected(): boolean {
    return this.visibleBundles.length > 0 &&
      this.visibleBundles.every((item: string): boolean => this.selectedBundles.includes(item));
  }

  @Computed
  get modeItems(): SegmentButtonV2Items {
    const labelStyle = new TextModifier().fontFamily(this.appStyle.fontFamily);
    return new SegmentButtonV2Items([
      { text: $r('app.string.access_control_mode_off'), textModifier: labelStyle },
      { text: $r('app.string.access_control_mode_blocked'), textModifier: labelStyle },
      { text: $r('app.string.access_control_mode_trusted'), textModifier: labelStyle }
    ]);
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.access_control_title') })
  }

  @Builder
  HeaderButton($$: AccessHeaderActionOption) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($$.icon)
        .fontSize(HEADER_ICON_SIZE)
        .fontColor([$$.highlight === true ? this.appStyle.palette.brand : $r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION)
    .systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText($$.label)
    .enabled($$.available)
    .onClick((): void => $$.invoke())
  }

  @Builder
  MoreMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.access_control_import') })
        .onClick((): void => this.openImport())
      MenuItem({ content: $r('app.string.access_control_export') })
        .enabled(this.selectedBundles.length > 0)
        .onClick((): void => { this.exportToClipboard(); })
      MenuItem({
        content: this.allVisibleSelected() ?
          $r('app.string.access_control_unselect_visible') : $r('app.string.access_control_select_visible')
      })
        .enabled(this.visibleCount > 0)
        .onClick((): void => this.toggleVisible())
      MenuItem({ content: $r('app.string.access_control_clear_list') })
        .enabled(this.selectedBundles.length > 0)
        .onClick((): void => this.clearActive())
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.activeMode !== 'off') {
        this.HeaderButton({
          icon: $r('sys.symbol.magnifyingglass'),
          label: $r('app.string.diagnostics_search'),
          available: this.editable(),
          invoke: (): void => this.toggleSearch()
        })
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(HEADER_ICON_SIZE)
            .fontColor([$r('sys.color.font_primary')])
        }
        .attributeModifier(HEADER_ACTION)
        .systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.action_more'))
        .enabled(this.editable())
        .bindMenu(this.MoreMenu)
      }
      this.HeaderButton({
        icon: $r('sys.symbol.checkmark'),
        label: $r('app.string.action_save'),
        available: this.editable() && this.dirty,
        highlight: this.dirty,
        invoke: (): void => { this.save(false); }
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  ModeControls() {
    Column({ space: 10 }) {
      CapsuleSegmentButtonV2({
        items: this.modeItems,
        selectedIndex: Math.max(0, VPN_APP_ACCESS_MODES.indexOf(this.activeMode)),
        $selectedIndex: (index: number): void => this.chooseMode(index),
        enableStateAnimation: !this.reduceMotion,
        itemSelectedBackgroundColor: ColorMetrics.numeric(this.appStyle.palette.brand),
        itemSelectedFontColor: ColorMetrics.numeric(this.appStyle.palette.onBrand),
        backgroundSystemMaterial: this.appStyle.regularMaterial()
      })
        .width('100%')
        .enabled(this.editable())

      if (this.activeMode !== 'off') {
        Row({ space: 8 }) {
          Text(this.activeMode === 'trusted' ?
            $r('app.string.access_control_trusted_summary', this.selectedBundles.length, MAX_VPN_TRUSTED_APPS) :
            $r('app.string.access_control_blocked_summary', this.selectedBundles.length, MAX_VPN_EXCLUDED_APPS))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
          Button($r('app.string.access_control_add_custom'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .controlSize(ControlSize.SMALL)
            .fontColor(this.appStyle.palette.brand)
            .enabled(this.editable())
            .onClick((): void => this.openImport())
        }
        .width('100%')

        if (this.searchShown) {
          TextInput({ text: this.query, placeholder: $r('app.string.access_control_search_hint') })
            .height(40)
            .width('100%')
            .onChange((text: string): void => {
              this.query = text;
              this.refreshRows();
            })
        }

        Scroll() {
          Row({ space: 8 }) {
            ForEach(ACCESS_APP_CATEGORIES, (category: AccessAppCategory) => {
              Button(this.categoryLabel(category))
                .controlSize(ControlSize.SMALL)
                .buttonStyle(this.activeCategory === category ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
                .backgroundColor(this.activeCategory === category ?
                  this.appStyle.palette.brand : $r('sys.color.comp_background_tertiary'))
                .fontColor(this.activeCategory === category ? this.appStyle.palette.onBrand : $r('sys.color.font_primary'))
                .onClick((): void => {
                  if (this.activeCategory !== category) {
                    this.activeCategory = category;
                    this.refreshRows();
                  }
                })
            }, (category: AccessAppCategory): string => category)
          }
          .padding({ top: 2, bottom: 2 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 8 })
  }

  @Builder
  ImportSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text($r('app.string.access_control_import_hint'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')

        Row({ space: 12 }) {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .height(36)
            .fontSize(14)
            .fontColor(this.appStyle.palette.onBrand)
            .iconColor(this.appStyle.palette.onBrand)
            .bgColor(this.appStyle.palette.brand)
            .onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.pasteFromClipboard();
              } else {
                this.importIssue = $r('app.string.access_control_clipboard_failed');
              }
            })
          Blank()
          Row({ space: 8 }) {
            Text($r('app.string.access_control_import_replace'))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
            Toggle({ type: ToggleType.Switch, isOn: this.importReplace })
              .selectedColor(this.appStyle.palette.brand)
              .onChange((isOn: boolean): void => { this.importReplace = isOn; })
          }
        }
        .width('100%')

        TextArea({ text: this.importDraft, placeholder: 'com.huawei.hmos.browser\ncom.droi.tong' })
          .maxLength(129 * MAX_VPN_TRUSTED_APPS)
          .height(180)
          .width('100%')
          .onChange((text: string): void => {
            this.importDraft = text;
            this.importIssue = '';
          })

        if (this.importIssue !== '') {
          Text(this.importIssue)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }

        Row({ space: 12 }) {
          Button($r('app.string.action_cancel'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .layoutWeight(1)
            .onClick((): void => { this.importShown = false; })
          Button($r('app.string.access_control_import_confirm'))
            .layoutWeight(1)
            .enabled(this.importDraft.trim() !== '')
            .onClick((): void => this.confirmImport())
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
    }
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  @Builder
  LeaveSheet() {
    Column({ space: 12 }) {
      Button($r('app.string.action_save'))
        .width('100%')
        .height(48)
        .enabled(!this.saving)
        .onClick((): void => { this.save(true); })
      Button($r('app.string.profile_discard'), { role: ButtonRole.ERROR })
        .width('100%')
        .height(48)
        .enabled(!this.saving)
        .onClick((): void => {
          this.leaveShown = false;
          this.approvedClose = true;
          this.onClose();
        })
      Button($r('app.string.profile_keep_editing'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .width('100%')
        .height(48)
        .enabled(!this.saving)
        .onClick((): void => { this.leaveShown = false; })
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  OffOverviewRows() {
    Column({ space: 8 }) {
      Text($r('app.string.access_control_off_desc'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(15)
        .lineHeight(22)
        .fontColor($r('sys.color.font_primary'))
      Text($r('app.string.access_control_saved_counts', this.excludedCount, this.trustedCount))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
  }

  @Builder
  CatalogList() {
    List() {
      ListItem() {
        Text(this.activeMode === 'trusted' ?
          $r('app.string.access_control_trusted_notice') : $r('app.string.access_control_blocked_notice'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(19)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 12 })
      }
      if (this.visibleCount === 0) {
        ListItem() {
          EmptyState({
            icon: $r('sys.symbol.magnifyingglass'),
            title: $r('app.string.access_control_no_match'),
            actionLabel: $r('app.string.access_control_add_custom'),
            onAction: (): void => this.openImport()
          })
        }
      } else {
        LazyForEach(this.rows, (item: AccessControlRowItem) => {
          ListItem() {
            AccessAppRow({
              item: item,
              selected: this.selectedBundles.includes(item.bundleName),
              first: item.key === this.firstKey,
              last: item.key === this.lastKey,
              onToggle: (): void => this.toggleBundle(item.bundleName)
            })
          }
        }, (item: AccessControlRowItem): string => item.key)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .enabled(!this.saving)
    .scrollBar(BarState.Off)
    .cachedCount(4, true)
    .clipContent(ContentClipMode.SAFE_AREA)
    .contentStartOffset(8)
    .contentEndOffset(24)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; this.load(); },
      pageHidden: (): void => { this.shown = false; },
      handleBack: (): boolean => this.handleBack()
    }) {
      Stack() {
        Column() {
          if (this.loadFailed) {
            Column({ space: 12 }) {
              Button($r('app.string.network_load_retry'))
                .enabled(!this.loading)
                .onClick((): void => { this.load(); })
            }
            .width('100%')
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24 })
          } else {
            ScrollControls({ controls: (): void => this.ModeControls() }) {
              if (this.activeMode === 'off') {
                Scroll() {
                  Column({ space: 16 }) {
                    SettingsSection({
                      footer: $r('app.string.access_control_platform_note'),
                      rows: (): void => this.OffOverviewRows()
                    })
                  }
                  .width('100%')
                  .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
                }
                .width('100%')
                .height('100%')
                .align(Alignment.Top)
                .clipContent(ContentClipMode.SAFE_AREA)
                .scrollBar(BarState.Off)
              } else {
                this.CatalogList()
              }
            }
          }
        }
        .width('100%')
        .height('100%')

        // 多个 bindSheet 必须挂在独立节点上，避免同节点后一个覆盖前一个。
        Column()
          .bindSheet($$this.importShown, this.ImportSheet, {
            title: { title: $r('app.string.access_control_import') },
            height: SheetSize.LARGE,
            preferType: SheetType.BOTTOM,
            showClose: true,
            systemMaterial: this.appStyle.sheetMaterial()
          })
        Column()
          .bindSheet($$this.leaveShown, this.LeaveSheet, {
            title: { title: $r('app.string.access_control_unsaved_title') },
            height: SheetSize.FIT_CONTENT,
            preferType: SheetType.BOTTOM,
            showClose: true,
            systemMaterial: this.appStyle.sheetMaterial(),
            onWillDismiss: (action: DismissSheetAction): void => {
              if (!this.saving) {
                action.dismiss();
              }
            }
          })
      }
      .width('100%')
      .height('100%')
    }
  }
}

@ComponentV2
struct AccessAppRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: AccessControlRowItem;
  @Param selected: boolean = false;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Event onToggle: () => void = (): void => {};

  build() {
    Column() {
      if (!this.first) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      }
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(this.item.custom ? $r('app.string.access_control_custom_app') : this.item.title)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.item.containerNote) {
              Text($r('app.string.access_control_container_badge'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(11)
                .fontColor(this.appStyle.palette.brand)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
            }
          }
          Text(this.item.bundleName)
            .fontFamily('monospace')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph(this.selected ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([this.selected ? this.appStyle.palette.brand : $r('sys.color.font_tertiary')])
      }
      .width('100%')
      .constraintSize({ minHeight: 62 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .accessibilitySelected(this.selected)
      .stateStyles({
        pressed: { .backgroundColor($r('sys.color.interactive_pressed')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => this.onToggle())
    }
    .width('100%')
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius({
      topLeft: this.first ? CARD_RADIUS : 0,
      topRight: this.first ? CARD_RADIUS : 0,
      bottomLeft: this.last ? CARD_RADIUS : 0,
      bottomRight: this.last ? CARD_RADIUS : 0
    })
    .clip(true)
  }
}
