import { common } from '@kit.AbilityKit';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupJumpItem } from './ProxyGroupJumpItem';
import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyGroupJumpList {
  @Param @Require browser: ProxyBrowser;
  @Param active: boolean = true;
  @Event onChoose: (groupName: string) => void = () => {};
  @Local rowExtent: number = 48;
  private scroller: ListScroller = new ListScroller();
  private focusTimer: number = -1;

  aboutToAppear(): void {
    const ui = this.getUIContext();
    const context = ui.getHostContext() as common.UIAbilityContext;
    const scale = ui.isFollowingSystemFontScale() ?
      Math.min(context.config.fontSizeScale ?? 1, ui.getMaxFontScale()) : 1;
    this.rowExtent = Math.max(48, Math.ceil(20 * scale + 24));
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
    return Math.min(320, this.rowExtent * this.browser.groups.length);
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
