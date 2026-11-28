import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { antifraudPicker } from '@kit.DeviceSecurityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';
import {
  CapsuleSegmentButtonV2, ColorMetrics, curves, LengthMetrics, SegmentButtonV2Items, SymbolGlyphModifier, TextModifier
} from '@kit.ArkUI';
import { peekAccessAppLabels, readAccessAppLabels, saveAccessAppLabels } from '../../client/AccessAppLabels';
import { connection, Connection } from '../../client/Connection';
import { peekVpnNetworkSettings, readVpnNetworkSettings, saveVpnNetworkSettings } from '../../client/VpnNetworkSettings';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { EmptyAction, IllustratedEmpty } from '../../components/IllustratedEmpty';
import { KeyedListSource } from '../../components/KeyedListSource';
import { ScrollDestination } from '../../components/ScrollDestination';
import { CARD_RADIUS, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { MAX_VPN_EXCLUDED_APPS, MAX_VPN_TRUSTED_APPS, VpnNetworkSettings } from '../../shared/VpnNetwork';
import { ACCESS_APP_CATEGORIES, AccessAppCategory } from './AccessControlCatalog';
import {
  AccessActiveMode, accessVisibleBundles, AccessControlChanges, AccessControlDraft, AccessListEntry, AccessPickedApp
} from './AccessControlLogic';
import { AccessLeaveSheet } from './AccessLeaveSheet';

const PICKER_MAX_SELECT = 50; // selectFraudApp 的 maxSelectNumber 只接受 1~50
const PICKER_UNSUPPORTED = 1017600002; // 设备类型不支持（PC/2in1 等）
const ACCESS_MODES: AccessActiveMode[] = ['trusted', 'blocked'];
const SEARCH_INPUT_ID = 'access_control_search';
const ROW_MIN_HEIGHT = 60;
const APP_ICON_SIZE = 40;
const FILTER_HEIGHT = 52;
const FILTER_CONTROL_SIZE = 36;
const EMPTY_HEIGHT = 420;
// 勾选时勾号从 0.6 弹到 1，带一点回弹；只作用于被点的那一行。
const CHECK_SPRING: ICurve = curves.springMotion(0.36, 0.7);
const SEARCH_SPRING: ICurve = curves.springMotion(0.34, 0.9);

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
  @Local private accessOn: boolean = false;
  @Local private activeMode: AccessActiveMode = 'blocked';
  @Local private selectedBundles: string[] = [];
  @Local private dirty: boolean = false;
  @Local private query: string = '';
  @Local private searchShown: boolean = false;
  @Local private activeCategory: AccessAppCategory = 'all';
  @Local private visibleCount: number = 0;
  @Local private popBundle: string = '';
  @Local private importShown: boolean = false;
  @Local private importDraft: string = '';
  @Local private importReplace: boolean = false;
  @Local private importIssue: ResourceStr = '';
  @Local private leaveShown: boolean = false;
  @Local private leaveChanges: AccessControlChanges = { fromMode: 'off', toMode: 'off', lists: [] };
  @Local private leaveIssue: ResourceStr = '';
  @Local private picking: boolean = false;
  private readonly pickerSupported: boolean = canIUse('SystemCapability.Security.Antifraud');
  private draft: AccessControlDraft = new AccessControlDraft(peekVpnNetworkSettings() ?? new VpnNetworkSettings(),
    peekAccessAppLabels());
  private rows: KeyedListSource<AccessListEntry> = new KeyedListSource<AccessListEntry>();
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

  private animate(curve: ICurve, change: () => void): void {
    if (this.reduceMotion) {
      change();
    } else {
      this.getUIContext().animateTo({ curve: curve }, change);
    }
  }

  private applyLoaded(settings: VpnNetworkSettings, labels?: Map<string, string>): void {
    this.draft = new AccessControlDraft(settings, labels ?? peekAccessAppLabels());
    this.syncFromDraft();
  }

  private syncFromDraft(): void {
    this.accessOn = this.draft.enabled();
    this.activeMode = this.draft.activeMode;
    this.selectedBundles = this.draft.activeList().slice();
    this.dirty = this.draft.isDirty();
    this.refreshRows();
  }

  private refreshRows(): void {
    const items = this.draft.entries(this.query, this.activeCategory, this.chinese);
    this.visibleBundles = accessVisibleBundles(items);
    this.visibleCount = this.visibleBundles.length;
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
      // 应用名只是显示用，读失败时退回包名，不影响名单编辑。
      const labels = await readAccessAppLabels(this.context()).catch((): Map<string, string> =>
        new Map<string, string>());
      if (!this.dirty) {
        this.applyLoaded(loaded, labels);
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

  private invalid(): boolean {
    return this.accessOn && this.activeMode === 'trusted' && this.selectedBundles.length === 0;
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

  private resetBrowsing(): void {
    this.searchShown = false;
    this.query = '';
    this.activeCategory = 'all';
    this.popBundle = '';
  }

  private setEnabled(on: boolean): void {
    if (!this.editable() || on === this.accessOn) {
      return;
    }
    this.draft.setEnabled(on);
    this.resetBrowsing();
    this.syncFromDraft();
  }

  private chooseMode(index: number): void {
    const next = ACCESS_MODES[index];
    if (!this.editable() || next === undefined || next === this.activeMode) {
      return;
    }
    this.draft.setMode(next);
    this.resetBrowsing();
    this.syncFromDraft();
  }

  private toggleBundle(bundleName: string): void {
    if (!this.editable() || !this.accessOn) {
      return;
    }
    const error = this.draft.toggle(bundleName);
    if (error !== '') {
      this.toast(this.errorText(error));
      return;
    }
    // 只给刚勾上的那一行播放勾号弹入，取消勾选只淡出。
    this.animate(CHECK_SPRING, (): void => {
      this.popBundle = this.draft.isSelected(bundleName) ? bundleName : '';
      this.selectedBundles = this.draft.activeList().slice();
    });
    this.dirty = this.draft.isDirty();
    if (this.activeCategory === 'selected') {
      this.refreshRows();
    }
  }

  private toggleVisible(): void {
    if (!this.editable() || !this.accessOn) {
      return;
    }
    const error = this.draft.toggleVisible(this.visibleBundles);
    if (error !== '') {
      this.toast(this.errorText(error));
      return;
    }
    this.popBundle = '';
    this.syncFromDraft();
  }

  private clearActive(): void {
    if (!this.editable() || !this.accessOn) {
      return;
    }
    this.draft.clearActive();
    this.popBundle = '';
    this.syncFromDraft();
  }

  private chooseCategory(category: AccessAppCategory): void {
    if (this.activeCategory !== category) {
      this.activeCategory = category;
      this.refreshRows();
    }
  }

  private openSearch(): void {
    this.animate(SEARCH_SPRING, (): void => {
      this.searchShown = true;
      this.activeCategory = 'all';
    });
    this.refreshRows();
  }

  private closeSearch(): void {
    this.animate(SEARCH_SPRING, (): void => {
      this.searchShown = false;
    });
    if (this.query !== '') {
      this.query = '';
      this.refreshRows();
    }
  }

  private openImport(): void {
    if (!this.editable() || !this.accessOn) {
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
    if (!this.editable() || !this.accessOn) {
      return;
    }
    const outcome = this.draft.applyImport(this.importDraft, this.context().applicationInfo.name, this.importReplace);
    if (!outcome.ok) {
      this.importIssue = this.errorText(outcome.error);
      return;
    }
    this.importShown = false;
    this.resetBrowsing();
    this.syncFromDraft();
    if (outcome.skippedOwn) {
      this.toast($r('app.string.access_control_import_own_skipped', outcome.addedCount));
    } else if (outcome.invalidCount > 0) {
      this.toast($r('app.string.access_control_import_partial', outcome.addedCount, outcome.invalidCount));
    } else {
      this.toast($r('app.string.access_control_import_done', outcome.addedCount));
    }
  }

  // HarmonyOS 不开放已安装应用列表；反诈应用选择器是唯一能让用户从本机应用里勾选的系统界面，
  // 依赖受限权限 USE_FRAUD_APP_PICKER（调试 Profile 需带该 ACL，见 docs/adr/0045）。
  private async pickInstalledApps(): Promise<void> {
    if (!this.editable() || !this.accessOn || this.picking) {
      return;
    }
    const remaining = this.draft.activeRemaining();
    if (remaining === 0) {
      this.toast(this.errorText('too_many_apps'));
      return;
    }
    this.picking = true;
    try {
      const result = await antifraudPicker.selectFraudApp(this.context(),
        { maxSelectNumber: Math.min(PICKER_MAX_SELECT, remaining) });
      const apps = result.appInfo.map((info: antifraudPicker.SingleAntifraudAppInfo): AccessPickedApp => ({
        bundleName: info.bundleName,
        label: info.label ?? ''
      }));
      // 选择器打开期间页面可能被重新加载或关掉开关，回来后以草稿当前状态为准。
      if (apps.length === 0 || !this.editable() || !this.draft.enabled()) {
        return;
      }
      const outcome = this.draft.applyPicked(apps, this.context().applicationInfo.name);
      if (!outcome.ok) {
        this.toast(this.errorText(outcome.error));
        return;
      }
      this.resetBrowsing();
      this.syncFromDraft();
      this.toast(outcome.skippedOwn ? $r('app.string.access_control_import_own_skipped', outcome.addedCount) :
        $r('app.string.access_control_pick_done', outcome.addedCount));
    } catch (error) {
      const code = (error as BusinessError).code;
      hilog.warn(0xD000, 'ArkClashAccess', '应用选择器失败 %{public}d', code);
      this.toast(code === PICKER_UNSUPPORTED ?
        $r('app.string.access_control_pick_unsupported') : $r('app.string.access_control_pick_failed'));
    } finally {
      this.picking = false;
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
      const labels = this.draft.labels;
      try {
        await saveAccessAppLabels(this.context(), labels, this.draft.allBundles());
      } catch (_error) {
        hilog.warn(0xD000, 'ArkClashAccess', '应用名保存失败');
      }
      this.resetBrowsing();
      this.applyLoaded(next, labels);
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
      this.closeSearch();
      return true;
    }
    if (!this.approvedClose && this.dirty) {
      // 草稿不是可观察对象，打开时取一次快照；抽屉开着时页面不可编辑，快照不会过期。
      this.leaveChanges = this.draft.changes();
      const issue = this.draft.validationError();
      this.leaveIssue = issue === '' ? '' : this.errorText(issue);
      this.leaveShown = true;
      return true;
    }
    return false;
  }

  private categoryLabel(category: AccessAppCategory): ResourceStr {
    switch (category) {
      case 'selected': return $r('app.string.access_control_cat_selected', this.selectedBundles.length);
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
      { text: $r('app.string.access_control_mode_trusted'), textModifier: labelStyle },
      { text: $r('app.string.access_control_mode_blocked'), textModifier: labelStyle }
    ]);
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.access_control_title') })
  }

  // 有未保存修改时保存按钮整颗填充品牌色，不只是换图标颜色。
  @Builder
  HeaderButton($$: AccessHeaderActionOption) {
    if ($$.highlight === true) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($$.icon).fontSize(HEADER_ICON_SIZE).fontColor([this.appStyle.palette.onBrand])
      }
      .attributeModifier(HEADER_ACTION)
      .backgroundColor(this.appStyle.palette.brand)
      .accessibilityText($$.label)
      .enabled($$.available)
      .onClick((): void => $$.invoke())
    } else {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($$.icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($$.label)
      .enabled($$.available)
      .onClick((): void => $$.invoke())
    }
  }

  @Builder
  MoreMenu() {
    Menu() {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rectangle_on_rectangle')),
        content: $r('app.string.access_control_export')
      })
        .enabled(this.selectedBundles.length > 0)
        .onClick((): void => { this.exportToClipboard(); })
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet')),
        content: this.allVisibleSelected() ?
          $r('app.string.access_control_unselect_visible') : $r('app.string.access_control_select_visible')
      })
        .enabled(this.visibleCount > 0)
        .onClick((): void => this.toggleVisible())
      MenuItemGroup() {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([$r('app.color.status_error')]),
          content: $r('app.string.access_control_clear_list')
        })
          .contentFontColor($r('app.color.status_error'))
          .enabled(this.selectedBundles.length > 0)
          .onClick((): void => this.clearActive())
      }
    }
  }

  @Builder
  AddMenu() {
    Menu() {
      if (this.pickerSupported) {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')),
          content: $r('app.string.access_control_pick_installed')
        })
          .enabled(!this.picking)
          .onClick((): void => { this.pickInstalledApps(); })
      }
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.character_textbox')),
        content: $r('app.string.access_control_import')
      })
        .onClick((): void => this.openImport())
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.accessOn) {
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
        available: this.editable() && this.dirty && !this.invalid(),
        highlight: this.dirty && !this.invalid(),
        invoke: (): void => { this.save(false); }
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  SwitchCard() {
    Row({ space: 12 }) {
      Text($r('app.string.access_control_title'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontWeight(500)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.accessOn })
        .selectedColor(this.appStyle.palette.brand)
        .enabled(this.editable())
        .onChange((isOn: boolean): void => this.setEnabled(isOn))
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 12 })
    .borderRadius(CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }

  @Builder
  ModeSegment() {
    CapsuleSegmentButtonV2({
      items: this.modeItems,
      selectedIndex: Math.max(0, ACCESS_MODES.indexOf(this.activeMode)),
      $selectedIndex: (index: number): void => this.chooseMode(index),
      enableStateAnimation: !this.reduceMotion,
      itemSelectedBackgroundColor: ColorMetrics.numeric(this.appStyle.palette.brand),
      itemSelectedFontColor: ColorMetrics.numeric(this.appStyle.palette.onBrand),
      backgroundSystemMaterial: this.appStyle.regularMaterial()
    })
      .width('100%')
      .enabled(this.editable())
  }

  // 筛选行吸在页面标题下方：左侧圆形搜索按钮，点开原地伸展为搜索框，筛选胶囊让位。
  @Builder
  FilterBar() {
    Row({ space: 6 }) {
      if (this.searchShown) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([this.appStyle.palette.brand])
          TextInput({ text: this.query, placeholder: $r('app.string.access_control_search_hint') })
            .id(SEARCH_INPUT_ID)
            .layoutWeight(1)
            .height(FILTER_CONTROL_SIZE)
            .padding(0)
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .caretColor(this.appStyle.palette.brand)
            .onAppear((): void => { this.getUIContext().getFocusController().requestFocus(SEARCH_INPUT_ID); })
            .onChange((text: string): void => {
              this.query = text;
              this.refreshRows();
            })
        }
        .layoutWeight(1)
        .height(FILTER_CONTROL_SIZE)
        .padding({ left: 12, right: 10 })
        .borderRadius(FILTER_CONTROL_SIZE / 2)
        .border({ width: 1.5, color: this.appStyle.palette.brand })
        .backgroundColor(this.appStyle.palette.cardBackground)
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY :
          TransitionEffect.scale({ x: 0.12, y: 1, centerX: 0 }).combine(TransitionEffect.OPACITY))
        Button($r('app.string.action_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .controlSize(ControlSize.SMALL)
          .fontColor(this.appStyle.palette.brand)
          .onClick((): void => this.closeSearch())
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY)
      } else {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([$r('sys.color.font_secondary')])
        }
        .width(FILTER_CONTROL_SIZE)
        .height(FILTER_CONTROL_SIZE)
        .backgroundColor(this.appStyle.palette.cardBackground)
        .accessibilityText($r('app.string.diagnostics_search'))
        .onClick((): void => this.openSearch())
        Scroll() {
          Row({ space: 4 }) {
            ForEach(ACCESS_APP_CATEGORIES, (category: AccessAppCategory) => {
              Button(this.categoryLabel(category))
                .height(32)
                .padding({ left: 12, right: 12 })
                .fontSize(14)
                .fontWeight(this.activeCategory === category ? 600 : 500)
                .fontColor(this.activeCategory === category ?
                  $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                .backgroundColor(this.activeCategory === category ?
                  this.appStyle.palette.cardBackground : Color.Transparent)
                .onClick((): void => this.chooseCategory(category))
            }, (category: AccessAppCategory): string => category)
          }
          .padding({ right: PAGE_GUTTER })
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(12) })
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY)
      }
    }
    .width('100%')
    .height(FILTER_HEIGHT)
    .padding({ left: PAGE_GUTTER, right: this.searchShown ? 8 : 0 })
    // 与 ScrollControls 一致：开着沉浸光感时只做背景模糊，关掉时用页面底色。
    .backgroundColor(this.appStyle.glass === 'none' ? this.appStyle.palette.pageBackground : Color.Transparent)
    .backdropBlur(this.appStyle.glass === 'none' ? 0 : 20)
  }

  @Builder
  AddRow(item: AccessListEntry) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(22).fontColor([this.appStyle.palette.brand])
      }
      .width(APP_ICON_SIZE)
      .height(APP_ICON_SIZE)
      Column({ space: 1 }) {
        Text($r('app.string.access_control_add_app'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(500)
          .fontColor(this.appStyle.palette.brand)
        if (this.invalid()) {
          Text($r('app.string.access_control_empty_trusted'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('app.color.status_error'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius({
      topLeft: item.first ? CARD_RADIUS : 0,
      topRight: item.first ? CARD_RADIUS : 0,
      bottomLeft: item.last ? CARD_RADIUS : 0,
      bottomRight: item.last ? CARD_RADIUS : 0
    })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.interactive_pressed')) },
      normal: { .backgroundColor(this.appStyle.palette.cardBackground) }
    })
    .accessibilityGroup(true)
    .enabled(this.editable())
    .bindMenu(this.AddMenu)
  }

  @Builder
  SectionLabel(item: AccessListEntry) {
    Text(item.labelKind === 'results' ?
      $r('app.string.access_control_results', item.count) : $r('app.string.access_control_common_apps'))
      .fontFamily(this.appStyle.fontFamily)
      .fontSize(13)
      .lineHeight(18)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .padding({ left: 4, top: item.labelKind === 'results' ? 6 : 20, bottom: 8 })
  }

  @Builder
  EmptyFront() {
    Row({ space: 10 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17).fontColor([this.appStyle.palette.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 7 }) {
        Row().width(96).height(8).borderRadius(4).backgroundColor(this.appStyle.palette.tileBackground)
        Row().width(62).height(6).borderRadius(3).backgroundColor(this.appStyle.palette.tileBackground)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  EmptyActions() {
    if (this.pickerSupported) {
      EmptyAction({
        icon: $r('sys.symbol.square_grid_2x2'),
        label: $r('app.string.access_control_pick_installed'),
        primary: true,
        motion: !this.reduceMotion,
        available: !this.picking,
        onPress: (): void => { this.pickInstalledApps(); }
      })
    }
    EmptyAction({
      icon: $r('sys.symbol.character_textbox'),
      label: $r('app.string.access_control_import'),
      primary: !this.pickerSupported,
      motion: !this.reduceMotion,
      onPress: (): void => this.openImport()
    })
  }

  @Builder
  EntryView(item: AccessListEntry) {
    if (item.kind === 'add') {
      this.AddRow(item)
    } else if (item.kind === 'label') {
      this.SectionLabel(item)
    } else if (item.kind === 'empty') {
      Column() {
        IllustratedEmpty({
          kind: 'empty',
          motion: !this.reduceMotion,
          heading: $r('app.string.access_control_no_match', this.query),
          front: (): void => this.EmptyFront(),
          actions: (): void => this.EmptyActions()
        })
      }
      .width('100%')
      .height(EMPTY_HEIGHT)
    } else {
      AccessAppRow({
        item: item,
        query: this.query,
        selected: this.selectedBundles.includes(item.bundleName),
        pop: this.popBundle === item.bundleName,
        motion: !this.reduceMotion,
        onToggle: (): void => this.toggleBundle(item.bundleName)
      })
    }
  }

  @Builder
  ImportSheet() {
    Scroll() {
      Column({ space: 12 }) {
        TextArea({ text: this.importDraft, placeholder: $r('app.string.access_control_import_placeholder') })
          .maxLength(129 * MAX_VPN_TRUSTED_APPS)
          .height(180)
          .width('100%')
          .fontFamily('monospace')
          .fontSize(14)
          .borderRadius(16)
          .backgroundColor(this.appStyle.palette.cardBackground)
          .caretColor(this.appStyle.palette.brand)
          .onChange((text: string): void => {
            this.importDraft = text;
            this.importIssue = '';
          })

        Row({ space: 10 }) {
          // 读取剪贴板必须经过系统粘贴控件，免权限且每次由用户确认。
          PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .height(32)
            .fontSize(14)
            .fontColor(this.appStyle.palette.brand)
            .backgroundColor(this.appStyle.palette.brandSoft)
            .onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.pasteFromClipboard();
              } else {
                this.importIssue = $r('app.string.access_control_clipboard_failed');
              }
            })
          Blank()
          Text($r('app.string.access_control_import_replace'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
          Toggle({ type: ToggleType.Switch, isOn: this.importReplace })
            .selectedColor(this.appStyle.palette.brand)
            .onChange((isOn: boolean): void => { this.importReplace = isOn; })
        }
        .width('100%')

        if (this.importIssue !== '') {
          Text(this.importIssue)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }

        Button($r('app.string.access_control_import_confirm'))
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontWeight(600)
          .backgroundColor(this.appStyle.palette.brand)
          .fontColor(this.appStyle.palette.onBrand)
          .enabled(this.importDraft.trim() !== '')
          .opacity(this.importDraft.trim() !== '' ? 1 : 0.4)
          .margin({ top: 8 })
          .onClick((): void => this.confirmImport())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  @Builder
  LeaveSheet() {
    AccessLeaveSheet({
      changes: this.leaveChanges,
      issue: this.leaveIssue,
      saving: this.saving,
      onSave: (): void => { this.save(true); },
      onDiscard: (): void => {
        this.leaveShown = false;
        this.approvedClose = true;
        this.onClose();
      }
    })
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
        if (this.loadFailed) {
          Column() {
            Button($r('app.string.network_load_retry'))
              .enabled(!this.loading)
              .onClick((): void => { this.load(); })
          }
          .width('100%')
          .height('100%')
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24 })
        } else {
          // 开关和模式随内容滚走，筛选行作为分组头吸顶；正文从页面标题后方穿过。
          List() {
            ListItem() {
              this.SwitchCard()
            }
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4 })
            if (this.accessOn) {
              ListItem() {
                this.ModeSegment()
              }
              .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 4 })
              ListItemGroup({ header: (): void => this.FilterBar() }) {
                LazyForEach(this.rows, (item: AccessListEntry) => {
                  ListItem() {
                    this.EntryView(item)
                  }
                  .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
                }, (item: AccessListEntry): string => item.key)
              }
            }
          }
          .width('100%')
          .height('100%')
          .sticky(StickyStyle.Header)
          .enabled(!this.saving)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(4, true)
          .clipContent(ContentClipMode.SAFE_AREA)
          .contentStartOffset(4)
          .contentEndOffset(24)
        }

        // 多个 bindSheet 必须挂在独立节点上，避免同节点后一个覆盖前一个。
        Column()
          .bindSheet($$this.importShown, this.ImportSheet, {
            title: { title: $r('app.string.access_control_import') },
            height: SheetSize.FIT_CONTENT,
            preferType: SheetType.BOTTOM,
            showClose: true,
            keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
            systemMaterial: this.appStyle.sheetMaterial()
          })
        Column()
          // 继续编辑靠下滑或点遮罩，抽屉里只放「放弃 / 保存」。
          .bindSheet($$this.leaveShown, this.LeaveSheet, {
            height: SheetSize.FIT_CONTENT,
            preferType: SheetType.BOTTOM,
            showClose: false,
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

/**
 * 应用行：40 圆角方块图标 + 名称 / 包名（搜索命中部分品牌色加粗）+ 选择圈。
 * 选中用实心勾，未选用空心圈；勾选时只有被点的那一行勾号弹入。
 */
@ComponentV2
struct AccessAppRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: AccessListEntry;
  @Param query: string = '';
  @Param selected: boolean = false;
  @Param pop: boolean = false;
  @Param motion: boolean = true;
  @Event onToggle: () => void = (): void => {};

  private split(text: string): string[] {
    const needle = this.query.trim().toLowerCase();
    const at = needle === '' ? -1 : text.toLowerCase().indexOf(needle);
    return at < 0 ? [text, '', ''] : [text.slice(0, at), text.slice(at, at + needle.length), text.slice(at + needle.length)];
  }

  @Computed
  get nameHit(): boolean {
    const needle = this.query.trim().toLowerCase();
    return needle !== '' && this.item.title.toLowerCase().includes(needle);
  }

  @Computed
  get nameParts(): string[] {
    return this.nameHit ? this.split(this.item.title) : [this.item.title, '', ''];
  }

  @Computed
  get bundleParts(): string[] {
    return this.nameHit ? [this.item.bundleName, '', ''] : this.split(this.item.bundleName);
  }

  @Builder
  AppIcon() {
    Stack() {
      Text(this.item.iconText)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(this.item.iconColor === '' ? $r('sys.color.font_secondary') : this.item.iconInk)
    }
    .width(APP_ICON_SIZE)
    .height(APP_ICON_SIZE)
    .borderRadius(12)
    .backgroundColor(this.item.iconColor === '' ? this.appStyle.palette.tileBackground : this.item.iconColor)
  }

  build() {
    Column() {
      if (!this.item.first) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 68 })
      }
      Row({ space: 12 }) {
        this.AppIcon()
        Column({ space: 1 }) {
          Row({ space: 6 }) {
            if (this.item.title === '') {
              Text($r('app.string.access_control_custom_app'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(16)
                .fontWeight(500)
                .fontColor($r('sys.color.font_primary'))
            } else {
              Text() {
                Span(this.nameParts[0])
                Span(this.nameParts[1]).fontColor(this.appStyle.palette.brand).fontWeight(600)
                Span(this.nameParts[2])
              }
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(16)
              .fontWeight(500)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.item.containerNote) {
              Text($r('app.string.access_control_container_badge'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'))
            }
          }
          Text() {
            Span(this.bundleParts[0])
            Span(this.bundleParts[1]).fontColor(this.appStyle.palette.brand).fontWeight(600)
            Span(this.bundleParts[2])
          }
          .fontFamily('monospace')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Stack() {
          if (this.selected) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(22)
              .fontColor([this.appStyle.palette.brand])
              .transition(this.motion && this.pop ?
                TransitionEffect.asymmetric(
                  TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY),
                  TransitionEffect.OPACITY) : TransitionEffect.IDENTITY)
          } else {
            SymbolGlyph($r('sys.symbol.circle'))
              .fontSize(22)
              .fontColor([$r('sys.color.font_tertiary')])
              .transition(this.motion ? TransitionEffect.OPACITY : TransitionEffect.IDENTITY)
          }
        }
        .width(24)
        .height(24)
      }
      .width('100%')
      .constraintSize({ minHeight: ROW_MIN_HEIGHT })
      .padding({ left: 16, right: 16, top: 9, bottom: 9 })
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
      topLeft: this.item.first ? CARD_RADIUS : 0,
      topRight: this.item.first ? CARD_RADIUS : 0,
      bottomLeft: this.item.last ? CARD_RADIUS : 0,
      bottomRight: this.item.last ? CARD_RADIUS : 0
    })
    .clip(true)
  }
}
