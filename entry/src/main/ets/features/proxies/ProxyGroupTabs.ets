import { AppGlyph } from '../../components/AppGlyph';
import { sheetMaterial } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupJumpList } from './ProxyGroupJumpList';
import { proxyTextScale } from './ProxyMetrics';
import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyGroupTabs {
  @Param @Require browser: ProxyBrowser;
  @Param active: boolean = false;
  @Param motionEnabled: boolean = false;
  @Local hasMore: boolean = false;
  @Local groupsShown: boolean = false;
  @Local fadeAmount: number = 0;
  @Local popupWidth: number = 280;
  private scroller: ListScroller = new ListScroller();
  @Local widths: Map<string, number> = new Map<string, number>();
  private measuredScale: number = 0;
  private fullWidth: number = 0;
  private viewport: number = 0;
  private total: number = 0;
  private listBound: boolean = false;

  aboutToAppear(): void {
    this.measureTabs();
  }

  aboutToDisappear(): void {
    this.groupsShown = false;
    this.listBound = false;
  }

  @Monitor('browser.groups', 'active')
  measureTabs(): void {
    const ui = this.getUIContext();
    const scale = proxyTextScale(ui);
    if (scale !== this.measuredScale) {
      this.widths.clear();
      this.measuredScale = scale;
    }
    let total = 0;
    for (const group of this.browser.groups) {
      let extent = this.widths.get(group.name);
      if (extent === undefined) {
        extent = Math.max(64, Math.ceil(ui.px2vp(ui.getMeasureUtils().measureText({
          textContent: group.name, fontSize: '15fp', fontWeight: 600
        }))) + 32);
        this.widths.set(group.name, extent);
      }
      total += extent;
    }
    this.total = total + Math.max(0, this.browser.groups.length - 1) * 8;
    this.hasMore = this.fullWidth > 0 && this.total + 32 > this.fullWidth;
    this.popupWidth = Math.min(280, Math.max(160, this.fullWidth - 32));
    this.updateFade(0);
    this.reveal();
  }

  @Monitor('browser.groupIndex')
  reveal(): void {
    if (!this.active) {
      this.groupsShown = false;
      return;
    }
    if (this.listBound && this.browser.groups.length > 0) {
      this.scroller.scrollToIndex(this.browser.groupIndex, false, ScrollAlign.CENTER);
      this.updateFade(0);
    }
  }


  private updateFade(delta: number): void {
    if (!this.listBound) {
      this.fadeAmount = 0;
      return;
    }
    const remaining = this.total + 16 + (this.hasMore ? 0 : 16) - this.viewport -
      this.scroller.currentOffset().xOffset - delta;
    this.fadeAmount = this.hasMore ? Math.max(0, Math.min(1, remaining / 24)) : 0;
  }

  private toggleGroups(): void {
    let widest = 160;
    for (const group of this.browser.groups) {
      const labelWidth = (this.widths.get(group.name) ?? 64) - 32;
      widest = Math.max(widest, labelWidth + (group.name === this.browser.currentGroup ? 60 : 40));
    }
    this.popupWidth = Math.min(280, widest, Math.max(160, this.fullWidth - 32));
    this.groupsShown = !this.groupsShown;
  }

  private chooseGroup(groupName: string): void {
    this.groupsShown = false;
    if (this.active) {
      this.browser.setCurrentGroup(groupName);
    }
  }

  @Builder
  private groupMenu() {
    Menu() {
      if ((this.browser.groups[this.browser.groupIndex]?.pinned ?? '') !== '') {
        MenuItem({ content: $r('app.string.proxy_pinned_name', this.browser.groups[this.browser.groupIndex]?.pinned ?? '') })
          .enabled(false)
        MenuItem({ content: $r('app.string.proxy_clear_pin') })
          .enabled(this.active && (this.browser.online || this.browser.offlineWritable))
          .onClick(() => this.browser.clearPin(this.browser.currentGroup))
      }
      if (this.browser.groups[this.browser.groupIndex]?.actualRetired === true) {
        MenuItem({ content: $r('app.string.proxy_actual_retired') })
          .enabled(false)
      }
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  @Builder
  private groupChoices() {
    ProxyGroupJumpList({
      browser: this.browser,
      active: this.active && this.groupsShown,
      onChoose: (groupName: string) => this.chooseGroup(groupName)
    })
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.End }) {
        List({ scroller: this.scroller, space: 8 }) {
          LazyForEach(this.browser.source, (group: ProxyGroupView) => {
            ListItem() {
              Button(group.name, { type: ButtonType.Capsule })
                .fontSize(15)
                .fontWeight(600)
                .labelStyle({ maxLines: 1, overflow: TextOverflow.Ellipsis })
                .width(this.widths.get(group.name) ?? 64)
                .height(36)
                .padding({ left: 16, right: 16 })
                .fontColor(this.browser.currentGroup === group.name ? $r('app.color.on_brand') : $r('sys.color.font_secondary'))
                .backgroundColor(this.browser.currentGroup === group.name ? $r('app.color.brand') : $r('app.color.card_background'))
                .animation({ duration: this.active && this.motionEnabled ? 160 : 0, curve: Curve.EaseOut })
                .accessibilitySelected(this.browser.currentGroup === group.name)
                .enabled(this.active)
                .onClick(() => this.chooseGroup(group.name))
            }
          }, (group: ProxyGroupView): string => group.key)
        }
        .width('100%')
        .height(36)
        .padding({ left: 16, right: this.hasMore ? 0 : 16 })
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .onAppear((): void => { this.listBound = true; this.reveal(); })
        .onDisAppear((): void => { this.listBound = false; })
        .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
          this.viewport = Number(after.width);
          this.updateFade(0);
        })
        .onWillScroll((offset: number, _state: ScrollState, _source: ScrollSource) => this.updateFade(offset))
        Row()
          .width(24)
          .height(36)
          .linearGradient({ direction: GradientDirection.Right, colors: [['#00000000', 0], [$r('app.color.page_background'), 1]] })
          .opacity(this.fadeAmount)
          .hitTestBehavior(HitTestMode.None)
      }
      .layoutWeight(1)
      .height(36)
      if (this.hasMore) {
        Button({ type: ButtonType.Circle }) {
          AppGlyph({ name: 'chevronDown', iconSize: 20 })
        }
        .width(36)
        .height(36)
        .padding(0)
        .backgroundColor($r('app.color.card_background'))
        .margin({ left: 8, right: 16 })
        .accessibilityText($r('app.string.proxy_groups'))
        .enabled(this.active)
        .onClick(() => this.toggleGroups())
        .bindPopup(this.groupsShown, {
          builder: this.groupChoices,
          placement: Placement.BottomRight,
          enableArrow: false,
          autoCancel: true,
          focusable: true,
          mask: true,
          targetSpace: 8,
          width: this.popupWidth,
          radius: 24,
          popupColor: $r('app.color.card_background'),
          systemMaterial: sheetMaterial(),
          onStateChange: (event: PopupStateChangeParam): void => {
            if (!event.isVisible) {
              this.groupsShown = false;
            }
          }
        })
      }
    }
    .width('100%')
    .height(36)
    .bindContextMenu(this.groupMenu, ResponseType.LongPress)
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      this.fullWidth = Number(after.width);
      this.measureTabs();
    })
  }
}
