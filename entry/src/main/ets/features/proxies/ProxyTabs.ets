import { ProxyBrowser } from './Proxies';
import { ProxyTabGrid } from './ProxyTabGrid';
import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyTabs {
  @Param @Require browser: ProxyBrowser;
  @Param active: boolean = false;
  @Param profileId: string = '';
  @Param contentInset: number = 0;
  @Param motionEnabled: boolean = false;
  @Local pageIndex: number = 0;
  @Event onListScroll: (offset: number, source: ScrollSource, scroller: Scroller) => void = () => {};
  @Event onScrollerReady: (scroller: Scroller) => void = () => {};
  @Event onSaveToLibrary: (group: string, node: string) => void = () => {};
  private controller: SwiperController = new SwiperController();
  private pendingIndex: number = -1;
  private requestedIndex: number = -1;
  private swiperBound: boolean = false;
  private boundGroup: string = '';
  private fallbackScroller: ListScroller = new ListScroller();
  private scrollers: Map<string, ListScroller> = new Map<string, ListScroller>();
  private readyGroups: Set<string> = new Set<string>();
  private restoreGroups: Set<string> = new Set<string>();

  aboutToAppear(): void {
    this.pageIndex = this.browser.groupIndex;
    this.requestedIndex = this.pageIndex;
    this.syncScrollers();
  }

  aboutToDisappear(): void {
    this.swiperBound = false;
    this.boundGroup = '';
    this.readyGroups.clear();
  }

  @Monitor('browser.groupIndex', 'active', 'motionEnabled')
  syncPage(): void {
    const index = this.browser.groupIndex;
    if (!this.swiperBound || this.browser.groups.length === 0) {
      this.pageIndex = index;
      this.requestedIndex = index;
      this.pendingIndex = -1;
      return;
    }
    if (!this.active || !this.motionEnabled) {
      this.pendingIndex = -1;
      this.requestedIndex = index;
      this.controller.changeIndex(index, false);
      return;
    }
    if (index !== this.requestedIndex) {
      this.pendingIndex = index;
      this.requestedIndex = index;
      this.controller.changeIndex(index, true);
    }
  }

  @Monitor('browser.groups', 'browser.groupIndex', 'active')
  syncScrollers(): void {
    for (const group of this.browser.groups) {
      if (!this.scrollers.has(group.key)) {
        this.scrollers.set(group.key, new ListScroller());
      }
    }
    this.pruneScrollers();
    const current = this.browser.groups[this.browser.groupIndex];
    if (!this.active || current === undefined) {
      this.boundGroup = '';
      return;
    }
    if (!this.readyGroups.has(current.key)) {
      return;
    }
    const scroller = this.scrollerFor(current);
    if (this.boundGroup !== current.key) {
      this.boundGroup = current.key;
      this.restoreGroups.add(current.key);
    }
    if (this.restoreGroups.delete(current.key)) {
      scroller.scrollTo({ xOffset: 0, yOffset: this.browser.tabOffsets.get(current.key) ?? 0, animation: false });
    }
    this.onScrollerReady(scroller);
  }

  @Monitor('profileId')
  resetScrollers(): void {
    this.boundGroup = '';
    this.syncScrollers();
  }

  private pruneScrollers(): void {
    this.scrollers.forEach((_scroller: ListScroller, key: string): void => {
      if (!this.readyGroups.has(key) && !this.browser.groups.some((group: ProxyGroupView): boolean => group.key === key)) {
        this.scrollers.delete(key);
        this.restoreGroups.delete(key);
      }
    });
  }

  private scrollerFor(group: ProxyGroupView): ListScroller {
    return this.scrollers.get(group.key) ?? this.fallbackScroller;
  }

  private groupReady(group: ProxyGroupView): void {
    if (this.browser.groups.includes(group)) {
      this.readyGroups.add(group.key);
      this.restoreGroups.add(group.key);
      this.syncScrollers();
    }
  }

  private groupRelease(group: ProxyGroupView): void {
    this.readyGroups.delete(group.key);
    if (this.boundGroup === group.key) {
      this.boundGroup = '';
    }
    this.pruneScrollers();
  }

  private changePage(index: number): void {
    if (this.pendingIndex >= 0 && this.pendingIndex !== index) {
      return;
    }
    this.pendingIndex = -1;
    this.requestedIndex = index;
    const group = this.browser.groups[index];
    if (this.active && group !== undefined && group.name !== this.browser.currentGroup) {
      this.browser.setCurrentGroup(group.name);
    }
  }

  private didScroll(group: ProxyGroupView, offset: number, source: ScrollSource): void {
    if (!this.readyGroups.has(group.key) || !this.browser.groups.includes(group)) {
      return;
    }
    const scroller = this.scrollerFor(group);
    this.browser.tabOffsets.set(group.key, Math.max(0, scroller.currentOffset().yOffset + offset));
    if (this.active && this.browser.currentGroup === group.name) {
      this.onListScroll(offset, source, scroller);
    }
  }

  build() {
    Swiper(this.controller) {
      LazyForEach(this.browser.source, (group: ProxyGroupView) => {
        ProxyTabGrid({
          browser: this.browser, group: group, scroller: this.scrollerFor(group),
          active: this.active && this.browser.currentGroup === group.name,
          contentInset: this.contentInset, motionEnabled: this.motionEnabled,
          onChoose: (node: string) => this.browser.choose(group.name, node),
          onTest: (node: string) => this.browser.test(group.name, node),
          onSaveToLibrary: (node: string) => this.onSaveToLibrary(group.name, node),
          onScrollerReady: (): void => this.groupReady(group),
          onScrollerRelease: (): void => this.groupRelease(group),
          onListScroll: (offset: number, source: ScrollSource) => this.didScroll(group, offset, source)
        })
      }, (group: ProxyGroupView): string => group.key)
    }
    .index($$this.pageIndex)
    .duration(this.motionEnabled ? 300 : 0)
    .indicator(false)
    .loop(false)
    .cachedCount(1)
    .onAppear((): void => { this.swiperBound = true; this.syncPage(); })
    .onDisAppear((): void => { this.swiperBound = false; })
    .onChange((index: number) => this.changePage(index))
    .onGestureSwipe((_index: number, _event: SwiperAnimationEvent): void => { this.pendingIndex = -1; })
    .width('100%')
    .height('100%')
  }
}
