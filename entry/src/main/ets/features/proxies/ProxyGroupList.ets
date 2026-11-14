import { curves, UIUtils } from '@kit.ArkUI';
import { EmptyState } from '../../components/EmptyState';
import { FLOATING_BAR_INSET, PAGE_GUTTER } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyFeedback } from './ProxyFeedback';
import { ProxyGroupHeader } from './ProxyGroupHeader';
import { proxyCardHeight, proxyTextScale } from './ProxyMetrics';
import { ProxyNodeLine } from './ProxyNodeLine';
import { ProxyGroupView, ProxyNodeRow } from './ProxyView';

interface ProxyHeaderBinding {
  group: ProxyGroupView;
}

interface ProxyBodyBinding {
  group: ProxyGroupView;
  row: ProxyNodeRow;
}

@ComponentV2
export struct ProxyGroupList {
  @Param @Require browser: ProxyBrowser;
  @Param @Require scroller: Scroller;
  @Param active: boolean = false;
  @Param pickerMode: boolean = false;
  @Param contentInset: number = 0;
  @Param motionEnabled: boolean = false;
  @Param feedbackVisible: boolean = false;
  @Event onLocate: (group: string) => void = () => {};
  @Event onListScroll: (offset: number, source: ScrollSource) => void = () => {};
  @Event onScrollerReady: () => void = () => {};
  @Event onScrollerRelease: () => void = () => {};
  @Local movingGroup: ProxyGroupView | undefined = undefined;
  private viewportHeight: number = 0;
  private textScale: number = 1;
  private listY: number = 0;
  private listBound: boolean = false;
  private groupTops: Map<string, number> = new Map<string, number>();

  aboutToAppear(): void {
    this.textScale = proxyTextScale(this.getUIContext());
  }

  aboutToDisappear(): void {
    this.listBound = false;
    this.finishReveal(false);
    this.groupTops.clear();
    this.onScrollerRelease();
  }

  @Monitor('active', 'motionEnabled', 'browser.query', 'browser.appearance.style', 'contentInset')
  settleReveal(): void {
    // Monitor可能由外层applySync触发；这里只清视觉状态，交给外层提交。
    this.finishReveal(false);
  }

  @Monitor('browser.groups')
  retireGroups(): void {
    if (this.movingGroup !== undefined && !this.browser.groups.includes(this.movingGroup)) {
      this.finishReveal(false);
    }
    this.groupTops.forEach((_top: number, key: string): void => {
      if (!this.browser.groups.some((group: ProxyGroupView): boolean => group.key === key)) {
        this.groupTops.delete(key);
      }
    });
  }

  private rowExtent(group: ProxyGroupView): number {
    return proxyCardHeight(group.cardType, this.textScale) + 8;
  }

  private headerExtent(): number {
    return 22 + 37 * this.textScale;
  }

  private canUse(group: ProxyGroupView): boolean {
    return this.listBound && this.active && this.browser.groups.includes(group);
  }

  private groupArea(group: ProxyGroupView, area: Area): void {
    if (!this.browser.groups.includes(group)) {
      return;
    }
    const top = Number(area.globalPosition.y);
    this.groupTops.set(group.key, top);
  }

  private followingGroup(group: ProxyGroupView): boolean {
    const moving = this.movingGroup;
    if (moving === undefined || !moving.reveal.running) {
      return false;
    }
    const movingIndex = this.browser.groups.indexOf(moving);
    return movingIndex >= 0 && this.browser.groups.indexOf(group) > movingIndex;
  }

  private followingOffset(group: ProxyGroupView): number {
    const moving = this.movingGroup;
    return moving !== undefined && this.followingGroup(group) ? moving.reveal.tailOffset : 0;
  }

  private motionCacheCount(): number {
    return this.movingGroup === undefined ? 2 :
      this.movingGroup.reveal.cacheCount(this.headerExtent());
  }

  private toggleGroup(group: ProxyGroupView): void {
    if (!this.canUse(group)) {
      return;
    }
    if (this.movingGroup !== undefined && this.movingGroup !== group) {
      this.finishReveal(true);
    }
    const top = this.groupTops.get(group.key);
    if (!this.motionEnabled || this.viewportHeight <= 0 || group.nodes.length === 0 || top === undefined) {
      this.finishReveal(true);
      UIUtils.applySync<void>((): void => this.browser.toggleGroup(group.name));
      return;
    }
    const reveal = group.reveal;
    const version = ++reveal.version;
    if (this.movingGroup !== group) {
      const expanded = group.expanded;
      const rows = group.rows.values();
      const distance = expanded ? Math.max(0, this.listY + this.contentInset - top) : 0;
      const rowExtent = this.rowExtent(group);
      const offset = this.scroller.currentOffset().yOffset;
      // List先一次提交固定窗口占位，真实动画只改裁剪边界和其后各组的同量位移。
      this.getUIContext().animateToImmediately({ duration: 0 }, (): void => {
        UIUtils.applySync<void>((): void => {
          reveal.firstRow = Math.floor(distance / rowExtent);
          reveal.crop = distance - reveal.firstRow * rowExtent;
          reveal.anchorOffset = offset - distance;
          if (!expanded) {
            this.browser.toggleGroup(group.name);
          }
          reveal.begin(expanded ? rows : group.rows.values(), rowExtent,
            this.viewportHeight - this.contentInset - this.headerExtent(), expanded);
          if (expanded) {
            this.browser.toggleGroup(group.name);
          }
          this.movingGroup = group;
        });
        if (distance > 0) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: reveal.anchorOffset, animation: false });
        }
      });
    } else {
      UIUtils.applySync<void>((): void => this.browser.toggleGroup(group.name));
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.28, 1), onFinish: (): void => {
      if (this.listBound && this.movingGroup === group && reveal.version === version) {
        this.finishReveal(true);
      }
    } }, (): void => {
      UIUtils.applySync<void>((): void => {
        reveal.extent = group.expanded ? reveal.fullExtent : 0;
        reveal.opacity = group.expanded ? 1 : 0;
      });
    });
  }

  private finishReveal(commit: boolean): void {
    const group = this.movingGroup;
    if (group === undefined) {
      return;
    }
    const reveal = group.reveal;
    const current = this.listBound && this.browser.groups.includes(group);
    const restore = current && group.expanded && (reveal.firstRow > 0 || reveal.crop > 0);
    const restoreOffset = reveal.anchorOffset + reveal.firstRow * reveal.rowExtent + reveal.crop;
    if (group.expanded && (reveal.firstRow > 0 || reveal.crop > 0)) {
      this.browser.listOffsets.set(group.profile, restoreOffset);
    }
    reveal.version++;
    if (commit && current) {
      this.getUIContext().animateToImmediately({ duration: 0 }, (): void => {
        UIUtils.applySync<void>((): void => {
          reveal.running = false;
          reveal.rows = [];
          this.movingGroup = undefined;
        });
        if (restore) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: restoreOffset, animation: false });
        }
      });
    } else {
      reveal.running = false;
      reveal.rows = [];
      this.movingGroup = undefined;
    }
  }

  private touch(event: TouchEvent): void {
    const group = this.movingGroup;
    if (event.type !== TouchType.Down || group === undefined || !this.listBound) {
      return;
    }
    const touchY = event.touches[0]?.y;
    const top = this.groupTops.get(group.key);
    const headerTop = Math.max(this.contentInset, (top ?? this.listY) - this.listY);
    if (touchY !== undefined && (touchY < headerTop || touchY > headerTop + this.headerExtent())) {
      this.finishReveal(true);
    }
  }

  private locate(group: ProxyGroupView): void {
    if (this.canUse(group)) {
      this.finishReveal(true);
      this.onLocate(group.name);
    }
  }

  @Builder
  private groupHeader($$: ProxyHeaderBinding) {
    ProxyGroupHeader({
      group: $$.group, online: this.browser.online, offlineWritable: this.browser.offlineWritable,
      showLocate: !this.pickerMode, collapsible: !this.pickerMode,
      active: this.active, motionEnabled: this.motionEnabled,
      onToggle: () => this.toggleGroup($$.group), onLocate: () => this.locate($$.group),
      onTest: (): void => { if (this.canUse($$.group)) { this.browser.test($$.group.name); } },
      onClearPin: (): void => { if (this.canUse($$.group)) { this.browser.clearPin($$.group.name); } }
    })
  }

  @Builder
  private nodeLine($$: ProxyBodyBinding) {
    Row() {
      ProxyNodeLine({
        row: $$.row, cardType: $$.group.cardType, active: this.active && $$.group.expanded,
        motionEnabled: this.motionEnabled, nestedSurface: true, groupType: $$.group.type,
        onChoose: (node: string) => this.browser.choose($$.group.name, node),
        onTest: (node: string) => this.browser.test($$.group.name, node)
      })
    }
    .width('100%')
    .height(this.rowExtent($$.group))
    .padding({ left: 10, right: 10 })
  }

  build() {
    List({ scroller: this.scroller, space: 8 }) {
      if (this.feedbackVisible) {
        ListItem() {
          ProxyFeedback({ browser: this.browser })
        }
      }
      LazyForEach(this.browser.source, (group: ProxyGroupView) => {
        ListItemGroup({
          header: (): void => this.groupHeader({ group: group }),
          headerStyle: ListItemGroupHeaderFooterStyle.NONE
        }) {
          if (group.reveal.running) {
            ListItem() {
              Column() {
                Column() {
                  ForEach(group.reveal.rows, (row: ProxyNodeRow) => {
                    this.nodeLine({ group: group, row: row })
                  }, (row: ProxyNodeRow): string => row.key)
                }
                .width('100%')
                .translate({ y: -group.reveal.crop })
              }
              .width('100%')
              .height(group.reveal.extent)
              .align(Alignment.TopStart)
              .justifyContent(FlexAlign.Start)
              .backgroundColor(Color.Transparent)
              .borderRadius(24)
              .opacity(group.reveal.opacity)
              .clip(true)
              .renderFit(RenderFit.TOP_LEFT)
            }
            .height(group.reveal.fullExtent)
          } else if (group.expanded && group.rowCount === 0) {
            ListItem() {
              EmptyState({ title: $r('app.string.proxy_group_empty'),
                hint: group.dynamic ? $r('app.string.proxy_dynamic_offline') : $r('app.string.proxy_group_empty_hint') })
            }
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(24)
          } else {
            LazyForEach(group.rows, (row: ProxyNodeRow) => {
              ListItem() {
                this.nodeLine({ group: group, row: row })
              }
            }, (row: ProxyNodeRow): string => row.key)
          }
        }
        .translate({ y: this.followingOffset(group) })
        .transition(TransitionEffect.IDENTITY)
        .onAreaChange((_before: Area, after: Area): void => this.groupArea(group, after))
      }, (group: ProxyGroupView): string => group.key)
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
    .safeAreaPadding({ top: this.contentInset })
    .contentStartOffset(12)
    .clipContent(ContentClipMode.BOUNDARY)
    .contentEndOffset(FLOATING_BAR_INSET)
    .cachedCount(this.motionCacheCount(), this.movingGroup !== undefined)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .onAppear((): void => { this.listBound = true; this.onScrollerReady(); })
    .onDisAppear((): void => { this.listBound = false; this.onScrollerRelease(); })
    .onAreaChange((_before: Area, after: Area): void => { this.listY = Number(after.globalPosition.y); })
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      this.viewportHeight = Number(after.height);
      this.textScale = proxyTextScale(this.getUIContext());
    })
    .onTouch((event: TouchEvent): void => this.touch(event))
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
      if (this.listBound) {
        // 手指拖动会打断展开动画；位移必须立即归零，否则后续分组继续带着 tailOffset 叠在内容上。
        if (source === ScrollSource.DRAG && this.movingGroup !== undefined) {
          this.finishReveal(true);
        }
        this.onListScroll(offset, source);
      }
    })
  }
}
