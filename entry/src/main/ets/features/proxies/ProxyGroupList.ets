import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { curves, UIUtils } from '@kit.ArkUI';
import { EmptyState } from '../../components/EmptyState';
import { FLOATING_BAR_INSET, PAGE_GUTTER } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupHeader } from './ProxyGroupHeader';
import { proxyCardHeight, proxyTextScale } from './ProxyMetrics';
import { ProxyNodeLine } from './ProxyNodeLine';
import { ProxyGroupView, ProxyLocateTarget, ProxyNodeRow } from './ProxyView';

// 对齐 FlClash 的 Curves.easeOutCubic 控制点，避免在点击或滚动回调里重复创建曲线。
const PROXY_LOCATE_CURVE = curves.cubicBezierCurve(0.215, 0.61, 0.355, 1);

// 逐帧更新布局高度；普通 height 动画只插值绘制尺寸，不能驱动懒加载列表逐帧排版。
@AnimatableExtend(ListItem)
function proxyPanelHeight(value: number) {
  .height(value)
}

interface ProxyHeaderBinding {
  group: ProxyGroupView;
}

interface ProxyBodyBinding {
  group: ProxyGroupView;
  row: ProxyNodeRow;
}

@ComponentV2
export struct ProxyGroupList {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require browser: ProxyBrowser;
  @Param @Require scroller: Scroller;
  @Param active: boolean = false;
  @Param pickerMode: boolean = false;
  @Param contentInset: number = 0;
  @Param motionEnabled: boolean = false;
  @Event onListScroll: (offset: number, source: ScrollSource) => void = () => {};
  @Event onScrollerReady: () => void = () => {};
  @Event onScrollerRelease: () => void = () => {};
  @Local movingGroup: ProxyGroupView | undefined = undefined;
  @Local viewportHeight: number = 0;
  private textScale: number = 1;
  private listY: number = 0;
  private listBound: boolean = false;
  private lastScrollOffset: number = 0;
  private locateTargetOffset: number | undefined = undefined;
  private groupTops: Map<string, number> = new Map<string, number>();

  aboutToAppear(): void {
    this.textScale = proxyTextScale(this.getUIContext());
  }

  aboutToDisappear(): void {
    this.stopLocateScroll();
    this.listBound = false;
    this.finishReveal(false);
    this.groupTops.clear();
    this.onScrollerRelease();
  }

  @Monitor('active', 'motionEnabled', 'browser.query', 'browser.appearance.style', 'contentInset')
  settleReveal(): void {
    // Monitor可能由外层applySync触发；这里只清视觉状态，交给外层提交。
    this.stopLocateScroll();
    this.finishReveal(false);
  }

  @Monitor('browser.groups')
  retireGroups(): void {
    this.stopLocateScroll();
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

  private foldAnimation(group: ProxyGroupView): AnimateParam {
    const version = group.reveal.version;
    return {
      curve: curves.springMotion(0.28, 1),
      onFinish: (): void => {
        if (this.listBound && this.movingGroup === group && group.reveal.version === version) {
          this.finishReveal(true);
        }
      }
    };
  }

  private canUse(group: ProxyGroupView): boolean {
    return this.listBound && this.active && this.browser.groups.includes(group);
  }

  private groupArea(group: ProxyGroupView, area: Area): void {
    if (!this.browser.groups.includes(group)) {
      return;
    }
    const top = Number(area.globalPosition.y);
    const extent = Number(area.height);
    this.groupTops.set(group.key, top);
    // 只在本组内容滚过标题后浮起；组尾推出标题时先收掉阴影。
    const under = group.expanded && !group.reveal.running ?
      Math.max(0, this.listY + this.contentInset - top) : 0;
    const floating = Math.min(1, under / 16);
    const remaining = extent - this.headerExtent() - under;
    const lift = Math.max(0, Math.min(1, Math.min(under, remaining) / 16));
    if (group.floating !== floating) {
      group.floating = floating;
    }
    if (group.lift !== lift) {
      group.lift = lift;
    }
  }

  private toggleGroup(group: ProxyGroupView): void {
    if (!this.canUse(group)) {
      return;
    }
    this.stopLocateScroll();
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
    reveal.version++;
    if (this.movingGroup !== group) {
      const expanded = group.expanded;
      const rows = group.rows.values();
      const distance = expanded ? Math.max(0, this.listY + this.contentInset - top) : 0;
      const rowExtent = this.rowExtent(group);
      const offset = this.scroller.currentOffset().yOffset;
      // 只绘制当前视口内的节点，ListItem 的真实高度驱动后续分组布局。
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
    UIUtils.applySync<void>((): void => {
      reveal.extent = group.expanded ? reveal.fullExtent : 0;
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

  private stopLocateScroll(): void {
    const locating = this.locateTargetOffset !== undefined;
    this.locateTargetOffset = undefined;
    if (locating && this.listBound) {
      this.scroller.scrollTo({
        xOffset: 0,
        yOffset: Math.max(0, this.lastScrollOffset),
        animation: false,
        canOverScroll: false
      });
    }
  }

  private locate(group: ProxyGroupView): void {
    if (!this.canUse(group)) {
      return;
    }
    this.stopLocateScroll();
    this.finishReveal(true);
    const target = UIUtils.applySync<ProxyLocateTarget | undefined>(
      (): ProxyLocateTarget | undefined => this.browser.locate(group.name));
    if (target === undefined || !this.canUse(group) || this.browser.groups[target.groupIndex] !== group) {
      return;
    }
    const currentOffset = this.scroller.currentOffset().yOffset;
    let groupY: number | undefined = undefined;
    try {
      const rect = this.scroller.getItemRect(target.groupIndex);
      if (rect.height > 0) {
        groupY = rect.y;
      }
    } catch (_error) {}
    if (groupY === undefined) {
      const top = this.groupTops.get(group.key);
      if (top !== undefined) {
        groupY = top - this.listY;
      }
    }
    if (groupY === undefined) {
      return;
    }
    // groupY 和期望可见位置（吸顶标题下方）各含同一份 headerExtent()，计算时抵消。
    const targetOffset = Math.max(0, currentOffset + groupY - this.contentInset +
      target.rowIndex * this.rowExtent(group));
    this.lastScrollOffset = currentOffset;
    this.locateTargetOffset = this.motionEnabled ? targetOffset : undefined;
    this.scroller.scrollTo({
      xOffset: 0,
      yOffset: targetOffset,
      canOverScroll: false,
      animation: this.motionEnabled ? { duration: 300, curve: PROXY_LOCATE_CURVE, canOverScroll: false } : false
    });
    if (!this.motionEnabled) {
      this.lastScrollOffset = this.scroller.currentOffset().yOffset;
    }
  }

  @Builder
  private groupHeader($$: ProxyHeaderBinding) {
    Stack() {
      if ($$.group.expanded || $$.group.reveal.running) {
        // 遮挡层随原生吸顶标题同帧移动，由本组边界裁剪，不影响其他分组的沉浸滚动。
        Column()
          .width('100%')
          .height(this.viewportHeight + 24)
          .position({ x: 0, y: -this.viewportHeight })
          .backgroundColor(this.appStyle.palette.pageBackground)
          .hitTestBehavior(HitTestMode.None)
      }
      ProxyGroupHeader({
        group: $$.group, online: this.browser.online, offlineWritable: this.browser.offlineWritable,
        showLocate: !this.pickerMode, collapsible: !this.pickerMode,
        active: this.active, motionEnabled: this.motionEnabled,
        onToggle: () => this.toggleGroup($$.group), onLocate: () => this.locate($$.group),
        onTest: (): void => { if (this.canUse($$.group)) { this.browser.test($$.group.name); } },
        onClearPin: (): void => { if (this.canUse($$.group)) { this.browser.clearPin($$.group.name); } }
      })
    }
    .width('100%')
    .height(this.headerExtent())
    .zIndex(1)
    .transition(TransitionEffect.IDENTITY)
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
      LazyForEach(this.browser.source, (group: ProxyGroupView) => {
        // 标题始终属于同一个原生分组；切换动画窗口时只替换节点区，避免重建文字和图标。
        ListItemGroup({
          header: (): void => this.groupHeader({ group: group }),
          headerStyle: ListItemGroupHeaderFooterStyle.NONE
        }) {
          if (group.reveal.running) {
            ListItem() {
              Column() {
                ForEach(group.reveal.rows, (row: ProxyNodeRow) => {
                  this.nodeLine({ group: group, row: row })
                }, (row: ProxyNodeRow): string => row.key)
              }
              .width('100%')
              .height(group.reveal.fullExtent + group.reveal.crop)
              .translate({ y: -group.reveal.crop })
              .alignItems(HorizontalAlign.Start)
            }
            .proxyPanelHeight(group.reveal.extent)
            .animation(this.foldAnimation(group))
            .align(Alignment.TopStart)
            .backgroundColor(this.appStyle.palette.cardBackground)
            .borderRadius({ bottomLeft: 24, bottomRight: 24 })
            .clip(true)
            .transition(TransitionEffect.IDENTITY)
          } else if (group.expanded && group.rowCount === 0) {
            ListItem() {
              EmptyState({ title: $r('app.string.proxy_group_empty'),
                hint: group.dynamic ? $r('app.string.proxy_dynamic_offline') : $r('app.string.proxy_group_empty_hint') })
            }
            .backgroundColor(this.appStyle.palette.cardBackground)
            .borderRadius({ bottomLeft: 24, bottomRight: 24 })
            .transition(TransitionEffect.IDENTITY)
          } else {
            LazyForEach(group.rows, (row: ProxyNodeRow) => {
              ListItem() {
                this.nodeLine({ group: group, row: row })
              }
              .padding({ bottom: row.last ? 2 : 0 })
              .backgroundColor(this.appStyle.palette.cardBackground)
              .borderRadius({ bottomLeft: row.last ? 24 : 0, bottomRight: row.last ? 24 : 0 })
              .transition(TransitionEffect.IDENTITY)
            }, (row: ProxyNodeRow): string => row.key)
          }
        }
        .backgroundColor(this.appStyle.palette.cardBackground)
        .borderRadius(24)
        .clip(true)
        .transition(TransitionEffect.IDENTITY)
        .onAreaChange((_before: Area, after: Area): void => this.groupArea(group, after))
      }, (group: ProxyGroupView): string => group.key)
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
    .safeAreaPadding({ top: this.contentInset })
    .contentStartOffset(0)
    .clipContent(ContentClipMode.BOUNDARY)
    .contentEndOffset((this.appStyle.floating ? FLOATING_BAR_INSET : 16))
    .cachedCount(2)
    .sticky(StickyStyle.Header)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .onAppear((): void => {
      this.listBound = true;
      this.onScrollerReady();
      this.lastScrollOffset = this.scroller.currentOffset().yOffset;
    })
    .onDisAppear((): void => {
      this.listBound = false;
      this.locateTargetOffset = undefined;
      this.onScrollerRelease();
    })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        // 触摸按下时立即停掉定位滚动，避免高速滚动期间屏蔽子按钮点击或与拖动冲突。
        this.stopLocateScroll();
      }
    })
    .onAreaChange((_before: Area, after: Area): void => { this.listY = Number(after.globalPosition.y); })
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      this.viewportHeight = Number(after.height);
      this.textScale = proxyTextScale(this.getUIContext());
    })
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
      if (this.listBound) {
        // 开始拖动前切回懒加载列表，避免在折叠窗口中滚动。
        if (source === ScrollSource.DRAG && this.movingGroup !== undefined) {
          this.finishReveal(true);
        }
        this.onListScroll(offset, source);
      }
    })
    .onDidScroll((_offset: number, _state: ScrollState): void => {
      if (!this.listBound) {
        return;
      }
      const offset = this.scroller.currentOffset().yOffset;
      this.lastScrollOffset = offset;
      // 小数 vp 舍入误差内视为到达目标；滚动到列表底部时由 isAtEnd 兜底结束定位状态。
      if (this.locateTargetOffset !== undefined &&
        (Math.abs(offset - this.locateTargetOffset) <= 0.5 ||
          (this.scroller.isAtEnd() && this.locateTargetOffset >= offset))) {
        this.locateTargetOffset = undefined;
      }
    })
  }
}
