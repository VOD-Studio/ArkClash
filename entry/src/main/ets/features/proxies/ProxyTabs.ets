import { PAGE_GUTTER } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyTabGrid } from './ProxyTabGrid';
import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyTabs {
  @Param @Require browser: ProxyBrowser;
  @Param active: boolean = false;
  @Param pickerMode: boolean = false;
  @Param profileId: string = '';
  @Event onListScroll: (offset: number, source: ScrollSource, scroller: Scroller) => void = () => {};
  @Event onScrollerReady: (scroller: Scroller) => void = () => {};
  private tabScroller: ListScroller = new ListScroller();
  private fallbackScroller: ListScroller = new ListScroller();
  private scrollers: Map<string, ListScroller> = new Map<string, ListScroller>();
  private focusTimer: number = -1;

  aboutToAppear(): void {
    this.syncScrollers();
  }

  aboutToDisappear(): void {
    const group = this.browser.groups[this.browser.groupIndex];
    if (group !== undefined) {
      this.browser.tabOffsets.set(group.key, this.scrollerFor(group).currentOffset().yOffset);
    }
    this.clearTimer();
  }

  @Monitor('browser.groups', 'browser.groupIndex', 'active')
  syncScrollers(): void {
    for (const group of this.browser.groups) {
      if (!this.scrollers.has(group.key)) {
        this.scrollers.set(group.key, new ListScroller());
      }
    }
    const current = this.browser.groups[this.browser.groupIndex];
    if (this.active && current !== undefined) {
      this.onScrollerReady(this.scrollerFor(current));
    }
    this.clearTimer();
    if (this.active && this.browser.groups.length > 0) {
      this.focusTimer = setTimeout((): void => {
        this.focusTimer = -1;
        this.tabScroller.scrollToIndex(this.browser.groupIndex, false, ScrollAlign.CENTER);
        if (current !== undefined) {
          this.scrollerFor(current).scrollTo({
            xOffset: 0, yOffset: this.browser.tabOffsets.get(current.key) ?? 0, animation: false
          });
        }
      }, 0);
    }
  }

  @Monitor('profileId')
  resetScrollers(): void {
    this.scrollers.clear();
    this.syncScrollers();
  }

  private clearTimer(): void {
    if (this.focusTimer !== -1) {
      clearTimeout(this.focusTimer);
      this.focusTimer = -1;
    }
  }

  private scrollerFor(group: ProxyGroupView): ListScroller {
    return this.scrollers.get(group.key) ?? this.fallbackScroller;
  }

  private changePage(index: number): void {
    const group = this.browser.groups[index];
    if (this.active && group !== undefined && group.name !== this.browser.currentGroup) {
      this.browser.setCurrentGroup(group.name);
    }
  }

  private locate(): void {
    const target = this.browser.locate(this.browser.currentGroup);
    const group = this.browser.groups[target?.groupIndex ?? -1];
    if (target !== undefined && group !== undefined) {
      this.scrollerFor(group).scrollToIndex(target.rowIndex, false, ScrollAlign.CENTER);
    }
  }

  private didScroll(group: ProxyGroupView, offset: number, source: ScrollSource): void {
    const scroller = this.scrollerFor(group);
    this.browser.tabOffsets.set(group.key, Math.max(0, scroller.currentOffset().yOffset + offset));
    this.onListScroll(offset, source, scroller);
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        List({ scroller: this.tabScroller, space: 8 }) {
          LazyForEach(this.browser.source, (group: ProxyGroupView) => {
            ListItem() {
              Button(group.name, { type: ButtonType.Capsule })
                .fontSize(14)
                .labelStyle({ maxLines: 1, overflow: TextOverflow.Ellipsis })
                .height(40)
                .padding({ left: 16, right: 16 })
                .fontColor(this.browser.currentGroup === group.name ? $r('app.color.on_brand') : $r('sys.color.font_primary'))
                .backgroundColor(this.browser.currentGroup === group.name ? $r('app.color.brand') : $r('app.color.card_background'))
                .accessibilitySelected(this.browser.currentGroup === group.name)
                .onClick(() => this.browser.setCurrentGroup(group.name))
            }
          }, (group: ProxyGroupView): string => group.key)
        }
        .height(44)
        .layoutWeight(1)
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        if (!this.pickerMode) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(18)
              .fontColor([$r('app.color.brand')])
          }
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.proxy_locate_selected'))
          .onClick(() => this.locate())
        }
        if ((this.browser.groups[this.browser.groupIndex]?.pinned ?? '') !== '') {
          Button($r('app.string.proxy_clear_pin'))
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .backgroundColor(Color.Transparent)
            .enabled(this.browser.online || this.browser.offlineWritable)
            .onClick(() => this.browser.clearPin(this.browser.currentGroup))
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.bolt'))
            .fontSize(18)
            .fontColor([$r('app.color.brand')])
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.proxy_test_current_group'))
        .enabled(this.browser.online && !(this.browser.groups[this.browser.groupIndex]?.testing ?? false))
        .onClick(() => this.browser.test(this.browser.currentGroup))
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      if (this.browser.groups[this.browser.groupIndex]?.actualRetired === true) {
        Column({ space: 4 }) {
          Text(this.browser.groups[this.browser.groupIndex]?.now ?? '')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Text($r('app.string.proxy_actual_retired'))
            .fontSize(12)
            .fontColor($r('app.color.warning'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      }
      Swiper() {
        LazyForEach(this.browser.source, (group: ProxyGroupView) => {
          ProxyTabGrid({
            group: group,
            scroller: this.scrollerFor(group),
            active: this.active && this.browser.currentGroup === group.name,
            onChoose: (node: string) => this.browser.choose(group.name, node),
            onTest: (node: string) => this.browser.test(group.name, node),
            onListScroll: (offset: number, source: ScrollSource) => this.didScroll(group, offset, source)
          })
        }, (group: ProxyGroupView): string => group.key)
      }
      .index(this.browser.groupIndex)
      .indicator(false)
      .loop(false)
      .cachedCount(1)
      .onChange((index: number) => this.changePage(index))
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
