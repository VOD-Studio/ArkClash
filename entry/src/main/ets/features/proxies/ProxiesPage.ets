import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { accessibility } from '@kit.AccessibilityKit';
import { common } from '@kit.AbilityKit';
import { Connection, connection } from '../../client/Connection';
import { EmptyState } from '../../components/EmptyState';
import { TabPage } from '../../components/TabPage';
import { FLOATING_BAR_INSET, PAGE_GUTTER, TAB_HEADER_HEIGHT } from '../../components/Theme';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupList } from './ProxyGroupList';
import {
  prepareSaveRuntimeProxy, proxySaveErrorText, resolveSaveProxyConflict, SaveProxyConflict
} from './ProxySaveToLibrary';
import { ProxyTabs } from './ProxyTabs';
import { ProxyToolbar } from './ProxyToolbar';

@ComponentV2
export struct ProxiesPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require scroller: Scroller;
  @Param topInset: number = 0;
  @Param visible: boolean = false;
  @Param profileId: string = '';
  @Param summary: ProfileSummary | undefined = undefined;
  @Param profileReady: boolean = false;
  @Param online: boolean = false;
  @Param offlineWritable: boolean = false;
  @Param pickerMode: boolean = false;
  @Param initialGroup: string = '';
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Event onOpenProfiles: () => void = () => {};
  @Local browser: ProxyBrowser = new ProxyBrowser();
  @Local link: Connection = connection;
  @Local boundScroller: Scroller = new Scroller();
  @Local reduceMotion: boolean = true;
  @Local saveConflictShown: boolean = false;
  @Local saveConflict: SaveProxyConflict | undefined = undefined;
  private saveConflictChoice: '' | 'overwrite' | 'rename' = '';
  private saveConflictGeneration: number = 0;
  private reductionListener: (enabled: boolean) => void = (enabled: boolean): void => {
    this.reduceMotion = enabled;
  };
  private availableWidth: number = 0;
  private scrollingDown: boolean = false;
  private savedProfile: string = '';
  private restoreListPending: boolean = true;
  private listOwner: string = '';
  private savingToLibrary: boolean = false;
  private saveConflictOpen: boolean = false;
  private saveGeneration: number = 0;

  aboutToAppear(): void {
    this.boundScroller = this.scroller;
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.configureBrowser();
  }

  aboutToDisappear(): void {
    accessibility.offAnimationReduceStateChange(this.reductionListener);
    this.listOwner = '';
    this.saveGeneration++;
    this.browser.suspend();
  }

  @Monitor('visible', 'profileId', 'summary', 'profileReady', 'initialGroup', 'online', 'offlineWritable',
    'link.mode', 'link.bootId', 'link.coreReady', 'link.configRevision')
  configureBrowser(): void {
    if (this.savedProfile !== this.profileId) {
      this.savedProfile = this.profileId;
      this.restoreListPending = true;
    }
    this.browser.configure({
      context: this.getUIContext().getHostContext() as common.UIAbilityContext,
      profile: this.profileId, summary: this.summary, ready: this.profileReady, visible: this.visible,
      online: this.link.coreReady, offlineWritable: this.offlineWritable,
      bootId: this.link.bootId, mode: this.link.mode === '' ? 'rule' : this.link.mode,
      configRevision: this.link.configRevision,
      picker: this.pickerMode, initialGroup: this.initialGroup
    });
  }

  private toast(message: Resource): void {
    if (!this.visible || this.profileId === '') {
      return;
    }
    const ui = this.getUIContext();
    const context = ui.getHostContext();
    if (context !== undefined) {
      ui.getPromptAction().showToast({ message: context.resourceManager.getStringSync(message.id) });
    }
  }

  private toastMessage(message: ResourceStr): void {
    if (!this.visible || this.profileId === '') {
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async saveNodeToLibrary(groupName: string, nodeId: string): Promise<void> {
    if (!this.visible || !this.link.coreReady || this.savingToLibrary || this.saveConflictOpen ||
      this.link.bootId === '' || this.link.configRevision <= 0) {
      return;
    }
    const generation = ++this.saveGeneration;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const bootId = this.link.bootId;
    const configRevision = this.link.configRevision;
    this.savingToLibrary = true;
    try {
      const result = await prepareSaveRuntimeProxy(context, bootId, configRevision, nodeId, groupName);
      if (!this.visible || generation !== this.saveGeneration) {
        return;
      }
      if (result.status === 'saved') {
        this.toastMessage($r('app.string.proxy_saved_to_library', result.savedName));
      } else if (result.conflict !== undefined) {
        this.presentSaveConflict(result.conflict, generation);
      }
    } catch (error) {
      if (this.visible && generation === this.saveGeneration) {
        this.toast(proxySaveErrorText((error as Error).message));
      }
    } finally {
      this.savingToLibrary = false;
    }
  }

  private presentSaveConflict(conflict: SaveProxyConflict, generation: number): void {
    if (!this.visible || this.saveConflictOpen || this.saveConflictShown) {
      return;
    }
    this.saveConflictOpen = true;
    this.saveConflict = conflict;
    this.saveConflictChoice = '';
    this.saveConflictGeneration = generation;
    this.saveConflictShown = true;
  }

  private handleSaveConflictDisappear(): void {
    this.saveConflictOpen = false;
    const conflict = this.saveConflict;
    const choice = this.saveConflictChoice;
    const generation = this.saveConflictGeneration;
    this.saveConflict = undefined;
    this.saveConflictChoice = '';
    if (!this.visible || conflict === undefined || choice === '' || generation !== this.saveGeneration) {
      return;
    }
    this.finishSaveConflict(conflict, choice, generation);
  }

  @Builder
  private SaveConflictOption(label: ResourceStr, icon: Resource, mode: 'overwrite' | 'rename') {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL, stateEffect: true }) {
      Row({ space: 12 }) {
        SymbolGlyph(icon).fontSize(22).fontColor([$r('sys.color.font_primary')])
        Text(label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17)
          .lineHeight(24)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(20)
    .onClick((): void => {
      this.saveConflictChoice = mode;
      this.saveConflictShown = false;
    })
  }

  @Builder
  private SaveConflictSheet() {
    Column({ space: 10 }) {
      if (this.saveConflict !== undefined) {
        Text($r('app.string.proxy_save_conflict_message', this.saveConflict.existingName))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 4 })
        this.SaveConflictOption($r('app.string.proxy_save_conflict_overwrite'),
          $r('sys.symbol.arrow_clockwise'), 'overwrite')
        this.SaveConflictOption($r('app.string.proxy_save_conflict_rename', this.saveConflict.suggestedName),
          $r('sys.symbol.plus_circle'), 'rename')
      }
      Button($r('app.string.action_cancel'))
        .fontFamily(this.appStyle.fontFamily)
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .margin({ top: 4 })
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => {
          this.saveConflictChoice = '';
          this.saveConflictShown = false;
        })
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 24 })
  }

  private async finishSaveConflict(conflict: SaveProxyConflict, mode: 'overwrite' | 'rename',
    generation: number): Promise<void> {
    if (this.savingToLibrary) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.savingToLibrary = true;
    try {
      const savedName = await resolveSaveProxyConflict(context, conflict, mode);
      if (this.visible && generation === this.saveGeneration) {
        this.toastMessage(mode === 'overwrite' ?
          $r('app.string.proxy_saved_overwritten', savedName) :
          $r('app.string.proxy_saved_to_library', savedName));
      }
    } catch (error) {
      if (this.visible && generation === this.saveGeneration) {
        this.toast(proxySaveErrorText((error as Error).message));
      }
    } finally {
      this.savingToLibrary = false;
    }
  }

  @Monitor('browser.notice', 'browser.noticeVersion')
  showNotice(): void {
    if (this.browser.notice !== '') {
      this.toast(this.noticeLabel());
    }
  }

  @Monitor('browser.loadError')
  showLoadError(): void {
    if (this.browser.loadError && this.browser.stale) {
      this.toast($r('app.string.proxy_stale'));
    }
  }

  @Monitor('browser.appearance.error')
  showPreferenceError(): void {
    if (this.browser.preferenceError) {
      this.toast($r('app.string.proxy_preferences_failed'));
    }
  }

  private noticeLabel(): Resource {
    switch (this.browser.notice) {
      case 'offline': return $r('app.string.proxy_test_offline');
      case 'unresolved': return $r('app.string.proxy_leaf_unresolved');
      case 'unsupported': return $r('app.string.proxy_group_unselectable');
      case 'notAddressable': return $r('app.string.proxy_node_not_addressable');
      case 'hostUnknown': return $r('app.string.proxy_host_unknown');
      case 'capacity': return $r('app.string.proxy_test_capacity');
      case 'noConclusion': return $r('app.string.proxy_test_no_conclusion');
      case 'cleanupFailed': return $r('app.string.proxy_cleanup_failed');
      case 'inconsistent': return $r('app.string.proxy_selection_inconsistent');
      case 'selectionFailed': return $r('app.string.proxy_selection_failed');
      case 'filtered': return $r('app.string.proxy_locate_filtered');
      default: return $r('app.string.proxy_not_ready');
    }
  }

  @Monitor('browser.appearance.style')
  resetBoundScroller(): void {
    if (!this.pickerMode) {
      this.boundScroller = this.scroller;
      this.restoreListPending = true;
      this.restoreListScroll();
    }
    this.resizeNodes();
  }

  @Monitor('browser.groups')
  restoreListScroll(): void {
    if (this.restoreListPending && this.visible && !this.pickerMode &&
      this.browser.groups.length > 0 && this.listOwner === 'groups') {
      this.restoreListPending = false;
      this.scroller.scrollTo({ xOffset: 0, yOffset: this.browser.listOffsets.get(this.profileId) ?? 0, animation: false });
    }
  }

  private listReady(owner: string): void {
    this.listOwner = owner;
    this.boundScroller = this.scroller;
    this.restoreListScroll();
  }

  private listRelease(owner: string): void {
    if (this.listOwner === owner) {
      this.listOwner = '';
      this.restoreListPending = true;
    }
  }

  private didScroll(offset: number, source: ScrollSource, scroller: Scroller): void {
    if (scroller !== this.boundScroller ||
      (!this.pickerMode && this.listOwner === '')) {
      return;
    }
    if (this.listOwner === 'groups' && scroller === this.scroller) {
      this.browser.listOffsets.set(this.profileId, Math.max(0, scroller.currentOffset().yOffset + offset));
    }
    if (!this.visible || this.pickerMode || source === ScrollSource.EDGE_EFFECT) {
      return;
    }
    let down = this.scrollingDown;
    if (scroller.currentOffset().yOffset <= 0 && offset <= 0) {
      down = false;
    } else if ((source === ScrollSource.DRAG || source === ScrollSource.FLING) && Math.abs(offset) >= 2) {
      down = offset > 0;
    }
    if (down !== this.scrollingDown) {
      this.scrollingDown = down;
      this.onScrollDirection(down);
    }
  }

  private resizeNodes(): void {
    if (this.availableWidth > 0) {
      this.browser.resize(this.availableWidth - PAGE_GUTTER * 2 -
        (this.pickerMode ? 0 : 20));
    }
  }

  private motionEnabled(): boolean {
    return this.visible && !this.reduceMotion;
  }

  @Builder
  private titleToolbar() {
    ProxyToolbar({
      browser: this.browser,
      active: this.visible,
      motionEnabled: this.motionEnabled()
    })
  }

  @Builder
  private emptyContent() {
    if (this.profileId === '') {
      EmptyState({
        icon: $r('sys.symbol.paperplane'),
        title: $r('app.string.home_no_profile'),
        hint: $r('app.string.home_no_profile_hint'),
        actionLabel: $r('app.string.proxy_open_profiles'),
        onAction: () => this.onOpenProfiles()
      })
    } else if (!this.link.coreReady) {
      EmptyState({
        title: $r('app.string.proxy_not_ready'),
        hint: $r('app.string.proxy_test_offline'),
        actionLabel: $r('app.string.proxy_start_core'),
        onAction: () => this.browser.startCore()
      })
        .enabled(!this.link.coreStarting)
    } else if (this.browser.query.trim() !== '') {
      EmptyState({
        title: $r('app.string.proxy_search_empty'),
        hint: $r('app.string.proxy_search_empty_hint'),
        actionLabel: $r('app.string.proxy_clear_search'),
        onAction: () => this.browser.setQuery('')
      })
    } else if (this.link.mode === 'direct') {
      EmptyState({ title: $r('app.string.mode_direct'), hint: $r('app.string.proxy_direct_empty') })
    } else if (this.browser.loadError) {
      EmptyState({
        title: $r('app.string.proxy_load_failed'), hint: $r('app.string.proxy_load_failed_hint'),
        actionLabel: $r('app.string.proxy_retry'), onAction: () => this.browser.refresh()
      })
    } else {
      EmptyState({
        icon: $r('sys.symbol.paperplane'),
        title: $r('app.string.proxies_empty'),
        hint: $r('app.string.proxies_empty_hint'),
        actionLabel: $r('app.string.proxy_open_profiles'),
        onAction: () => this.onOpenProfiles()
      })
    }
  }

  @Builder
  private pageContent() {
    Column() {
      if (this.pickerMode) {
        ProxyToolbar({ browser: this.browser, pickerMode: true, active: this.visible,
          motionEnabled: this.motionEnabled() })
      }
      if (this.browser.groups.length === 0) {
        List({ scroller: this.scroller }) {
          ListItem() {
            if (!this.browser.loadError && (this.browser.loading || !this.profileReady) && this.profileId !== '') {
              Column({ space: 12 }) {
                LoadingProgress()
                  .width(32)
                  .height(32)
                  .color(this.appStyle.palette.brand)
                  .enableLoading(this.visible)
                Text($r('app.string.proxy_loading'))
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            } else {
              this.emptyContent()
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
        .safeAreaPadding({ top: this.pickerMode ? 0 : this.topInset + TAB_HEADER_HEIGHT })
        .contentStartOffset(12)
        .contentEndOffset((this.appStyle.floating ? FLOATING_BAR_INSET : 16))
        .clipContent(ContentClipMode.BOUNDARY)
        .edgeEffect(EdgeEffect.Spring)
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (this.listOwner === 'empty') { this.didScroll(offset, source, this.scroller); }
        })
        .onAppear((): void => this.listReady('empty'))
        .onDisAppear((): void => this.listRelease('empty'))
      } else if (this.pickerMode) {
        ProxyTabs({
          browser: this.browser, active: this.visible, profileId: this.profileId,
          contentInset: 0,
          motionEnabled: this.motionEnabled(),
          onSaveToLibrary: (group: string, node: string): void => { this.saveNodeToLibrary(group, node); },
          onScrollerReady: (scroller: Scroller) => { this.listOwner = ''; this.boundScroller = scroller; },
          onListScroll: (offset: number, source: ScrollSource, scroller: Scroller) => this.didScroll(offset, source, scroller)
        })
          .layoutWeight(1)
      } else {
        ProxyGroupList({
          browser: this.browser, scroller: this.scroller, active: this.visible, pickerMode: this.pickerMode,
          contentInset: this.topInset + TAB_HEADER_HEIGHT,
          motionEnabled: this.motionEnabled(),
          onSaveToLibrary: (group: string, node: string): void => { this.saveNodeToLibrary(group, node); },
          onScrollerReady: (): void => this.listReady('groups'),
          onScrollerRelease: (): void => this.listRelease('groups'),
          onListScroll: (offset: number, source: ScrollSource) => this.didScroll(offset, source, this.scroller)
        })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.pickerMode ? 8 : 0 })
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      this.availableWidth = Number(after.width);
      this.resizeNodes();
    })
  }

  build() {
    Column() {
      if (this.pickerMode) {
        this.pageContent()
      } else {
        TabPage({
          title: $r('app.string.tab_proxies'),
          scroller: this.boundScroller,
          topInset: this.topInset,
          contentOwnsScroll: true,
          customTitle: true,
          titleContent: (): void => this.titleToolbar(),
          content: (): void => this.pageContent()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.appStyle.palette.pageBackground)
    .bindSheet($$this.saveConflictShown, this.SaveConflictSheet, {
      title: { title: $r('app.string.proxy_save_conflict_title') },
      height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
      systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
      onDisappear: (): void => { this.handleSaveConflictDisappear(); }
    })
  }
}
