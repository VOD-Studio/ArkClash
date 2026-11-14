import { proxyTextScale } from './ProxyMetrics';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupJumpItem } from './ProxyGroupJumpItem';
import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyGroupJumpList {
  @Param @Require browser: ProxyBrowser;
  @Param active: boolean = true;
  @Event onChoose: (groupName: string) => void = () => {};
  @Local rowExtent: number = 44;
  private scroller: ListScroller = new ListScroller();
  private focusTimer: number = -1;

  aboutToAppear(): void {
    this.rowExtent = Math.ceil(20 * proxyTextScale(this.getUIContext()) + 24);
    this.focusCurrentGroup();
  }

  aboutToDisappear(): void {
    this.clearFocusTimer();
  }

  @Monitor('active', 'browser.groupIndex')
  focusCurrentGroup(): void {
    this.clearFocusTimer();
    if (this.active && this.browser.groups.length > 0) {
      this.focusTimer = setTimeout((): void => {
        this.focusTimer = -1;
        if (this.active) {
          this.scroller.scrollToIndex(this.browser.groupIndex, false, ScrollAlign.CENTER);
        }
      }, 0);
    }
  }

  private clearFocusTimer(): void {
    if (this.focusTimer !== -1) {
      clearTimeout(this.focusTimer);
      this.focusTimer = -1;
    }
  }

  private viewportHeight(): number {
    return Math.min(7.5, this.browser.groups.length) * this.rowExtent;
  }

  build() {
    Column() {
      List({ scroller: this.scroller, initialIndex: this.browser.groupIndex }) {
        LazyForEach(this.browser.source, (group: ProxyGroupView) => {
          ListItem() {
            ProxyGroupJumpItem({
              browser: this.browser,
              group: group,
              rowExtent: this.rowExtent,
              onChoose: (groupName: string) => this.onChoose(groupName)
            })
          }
        }, (group: ProxyGroupView): string => group.key)
      }
      .width('100%')
      .height(this.viewportHeight())
      .cachedCount(2)
      .scrollBar(BarState.Auto)
      .accessibilityText($r('app.string.proxy_jump_group'))
    }
    .width('100%')
    .padding(8)
  }
}
