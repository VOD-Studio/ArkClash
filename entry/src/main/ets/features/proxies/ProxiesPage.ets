import { common } from '@kit.AbilityKit';
import {
  HdsNavigation, HdsNavigationTitleMode, HdsTitleBarContentStyle, hdsMaterial, ScrollEffectType
} from '@kit.UIDesignKit';
import { Connection, connection } from '../../client/Connection';
import { EmptyState } from '../../components/EmptyState';
import { PAGE_GUTTER } from '../../components/Theme';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { ProxyBrowser } from './Proxies';
import { ProxyFeedback } from './ProxyFeedback';
import { ProxyGroupList } from './ProxyGroupList';
import { ProxyTabs } from './ProxyTabs';
import { ProxyToolbar } from './ProxyToolbar';
import { ProxyGroupView } from './ProxyView';

const PROXY_TITLE_STYLE: HdsTitleBarContentStyle = {
  titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
  menuStyle: { iconColor: $r('sys.color.icon_primary'), backgroundColor: $r('sys.color.comp_background_tertiary') }
};

@ComponentV2
export struct ProxiesPage {
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
  private scrollingDown: boolean = false;
  private locateTimer: number = -1;
  private savedProfile: string = '';
  private savedLayout: string = 'list';
  private restoreListPending: boolean = true;

  aboutToAppear(): void {
    this.boundScroller = this.scroller;
    this.configureBrowser();
  }

  aboutToDisappear(): void {
    if (this.browser.style.type === 'list') {
      this.browser.listOffsets.set(this.profileId, this.scroller.currentOffset().yOffset);
    }
    this.clearLocateTimer();
    this.browser.suspend();
  }

  @Monitor('visible', 'profileId', 'summary', 'profileReady', 'initialGroup', 'online', 'offlineWritable',
    'link.mode', 'link.bootId')
  configureBrowser(): void {
    if (this.savedProfile !== this.profileId) {
      if (this.savedProfile !== '' && this.savedLayout === 'list') {
        this.browser.listOffsets.set(this.savedProfile, this.scroller.currentOffset().yOffset);
      }
      this.savedProfile = this.profileId;
      this.restoreListPending = true;
    }
    if (!this.visible) {
      this.clearLocateTimer();
    }
    this.browser.configure({
      context: this.getUIContext().getHostContext() as common.UIAbilityContext,
      profile: this.profileId, summary: this.summary, ready: this.profileReady, visible: this.visible,
      online: this.online, offlineWritable: this.offlineWritable,
      bootId: this.link.bootId, mode: this.link.mode === '' ? 'rule' : this.link.mode,
      picker: this.pickerMode, initialGroup: this.initialGroup
    });
  }

  @Monitor('browser.appearance.style')
  resetBoundScroller(): void {
    if (this.savedLayout === 'list' && this.browser.style.type !== 'list') {
      this.browser.listOffsets.set(this.profileId, this.scroller.currentOffset().yOffset);
    }
    this.savedLayout = this.browser.style.type;
    if (this.browser.style.type === 'list') {
      this.boundScroller = this.scroller;
      this.restoreListPending = true;
      this.restoreListScroll();
    }
  }

  @Monitor('browser.groups')
  restoreListScroll(): void {
    if (this.restoreListPending && this.visible && this.browser.style.type === 'list' && this.browser.groups.length > 0) {
      this.restoreListPending = false;
      this.clearLocateTimer();
      this.locateTimer = setTimeout((): void => {
        this.locateTimer = -1;
        this.scroller.scrollTo({ xOffset: 0, yOffset: this.browser.listOffsets.get(this.profileId) ?? 0, animation: false });
      }, 0);
    }
  }

  private clearLocateTimer(): void {
    if (this.locateTimer !== -1) {
      clearTimeout(this.locateTimer);
      this.locateTimer = -1;
    }
  }

  private jumpToGroup(groupName: string): void {
    if (this.browser.style.type !== 'list') {
      return;
    }
    this.clearLocateTimer();
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = -1;
      const index = this.browser.groups.findIndex((group: ProxyGroupView): boolean => group.name === groupName);
      if (this.visible && this.browser.style.type === 'list' && index >= 0) {
        this.scroller.scrollToIndex(index, false, ScrollAlign.START);
      }
    }, 0);
  }

  private locate(groupName: string): void {
    const target = this.browser.locate(groupName);
    if (target === undefined) {
      return;
    }
    this.clearLocateTimer();
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = -1;
      if (this.visible) {
        if (this.scroller instanceof ListScroller) {
          this.scroller.scrollToItemInGroup(target.groupIndex, target.rowIndex, false, ScrollAlign.CENTER);
        } else {
          this.scroller.scrollToIndex(target.groupIndex, false, ScrollAlign.START);
        }
      }
    }, 0);
  }

  private didScroll(offset: number, source: ScrollSource, scroller: Scroller): void {
    if (this.browser.style.type === 'list' && this.visible) {
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
    Column({ space: 8 }) {
      if (this.profileId !== '') {
        Column({ space: 8 }) {
          ProxyToolbar({
            browser: this.browser, pickerMode: this.pickerMode, active: this.visible,
            onOpenProfiles: () => this.onOpenProfiles(),
            onLocate: (groupName: string) => this.jumpToGroup(groupName)
          })
          ProxyFeedback({ browser: this.browser })
        }
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      }
      if ((this.browser.loading || !this.profileReady) && this.profileId !== '') {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.brand'))
            .enableLoading(this.visible)
          Text($r('app.string.proxy_loading'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.browser.groups.length === 0) {
        Column() {
          this.emptyContent()
        }
        .layoutWeight(1)
        .width('100%')
      } else if (this.pickerMode || this.browser.style.type === 'tab') {
        ProxyTabs({
          browser: this.browser, active: this.visible, pickerMode: this.pickerMode, profileId: this.profileId,
          onScrollerReady: (scroller: Scroller) => { this.boundScroller = scroller; },
          onListScroll: (offset: number, source: ScrollSource, scroller: Scroller) => this.didScroll(offset, source, scroller)
        })
          .layoutWeight(1)
      } else {
        ProxyGroupList({
          browser: this.browser, scroller: this.scroller, active: this.visible, pickerMode: this.pickerMode,
          onLocate: (group: string) => this.locate(group),
          onListScroll: (offset: number, source: ScrollSource) => this.didScroll(offset, source, this.scroller)
        })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.pickerMode ? 8 : this.topInset + 64 })
    .onSizeChange((_before: SizeOptions, after: SizeOptions) => this.browser.resize(Number(after.width) - PAGE_GUTTER * 2))
  }

  build() {
    Column() {
    if (this.pickerMode) {
      Column() {
        this.pageContent()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    } else {
      HdsNavigation() {
        this.pageContent()
      }
      .titleBar({
        avoidLayoutSafeArea: true,
        style: {
          scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          originalStyle: { contentStyle: PROXY_TITLE_STYLE },
          scrollEffectStyle: { contentStyle: PROXY_TITLE_STYLE }
        },
        content: { title: { mainTitle: $r('app.string.tab_proxies') } }
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .bindToScrollable([this.boundScroller])
    }
    }
    .width('100%')
    .height('100%')
  }
}
