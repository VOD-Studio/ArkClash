import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { AppearanceState, appAppearance } from './AppearanceState';
import { HEADER_ACTION_SIZE, PAGE_GUTTER, immersiveTitleStyle } from './Theme';
import { WindowInsets, windowInsets } from './WindowInsets';

const DEFAULT_TITLE_HEIGHT = 56;

@Builder
function emptyActions() {}

@ComponentV2
struct DestinationToolbar {
  @BuilderParam heading: () => void = emptyActions;
  @BuilderParam actions: () => void = emptyActions;

  build() {
    Row() {
      Row() { this.heading() }.layoutWeight(1).height('100%')
      this.actions()
    }
    .width('100%').height('100%')
    .padding({ left: PAGE_GUTTER + HEADER_ACTION_SIZE })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

@ComponentV2
export struct ScrollDestination {
  @Param @Require heading: () => void;
  @Param actions: () => void = emptyActions;
  @BuilderParam content: () => void = emptyActions;
  @Event pageShown: (reason: VisibilityChangeReason) => void = () => {};
  @Event pageHidden: (reason: VisibilityChangeReason) => void = () => {};
  @Event handleBack: () => boolean = () => false;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private insets: WindowInsets = windowInsets();
  @Local private titleAreaHeight: number = 0;

  @Builder
  Toolbar() {
    DestinationToolbar({ heading: this.heading, actions: this.actions })
      .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
        const height = Number(next.height);
        if (height > 0) { this.titleAreaHeight = height; }
      })
  }

  build() {
    HdsNavDestination() {
      Stack() { this.content() }
        .width('100%').height('100%')
        // HDS 自定义标题区的实测高度已经包含状态栏。首帧先按单行标题预留。
        .safeAreaPadding({
          top: this.titleAreaHeight || this.getUIContext().px2vp(this.insets.top) + DEFAULT_TITLE_HEIGHT,
          bottom: this.getUIContext().px2vp(this.insets.bottom)
        })
    }
    .titleBar({
      padding: { start: LengthMetrics.vp(PAGE_GUTTER), end: LengthMetrics.vp(PAGE_GUTTER) },
      avoidLayoutSafeArea: true,
      style: immersiveTitleStyle(this.appStyle.glass),
      content: { stackBuilderContent: { builder: (): void => this.Toolbar(), updated: true } }
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(false)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .backgroundColor(this.appStyle.palette.pageBackground)
    .onShown((reason: VisibilityChangeReason): void => this.pageShown(reason))
    .onHidden((reason: VisibilityChangeReason): void => this.pageHidden(reason))
    .onBackPressed((): boolean => this.handleBack())
  }
}
