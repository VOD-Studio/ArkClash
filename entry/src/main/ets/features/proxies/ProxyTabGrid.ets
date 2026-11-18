import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { EmptyState } from '../../components/EmptyState';
import { FLOATING_BAR_INSET, PAGE_GUTTER } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupTabs } from './ProxyGroupTabs';
import { ProxyNodeLine } from './ProxyNodeLine';
import { ProxyGroupView, ProxyNodeRow } from './ProxyView';

@ComponentV2
export struct ProxyTabGrid {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require browser: ProxyBrowser;
  @Param @Require group: ProxyGroupView;
  @Param @Require scroller: Scroller;
  @Param active: boolean = false;
  @Param contentInset: number = 0;
  @Param motionEnabled: boolean = false;
  @Event onChoose: (node: string) => void = () => {};
  @Event onTest: (node: string) => void = () => {};
  @Event onListScroll: (offset: number, source: ScrollSource) => void = () => {};
  @Event onScrollerReady: () => void = () => {};
  @Event onScrollerRelease: () => void = () => {};
  private listBound: boolean = false;

  aboutToDisappear(): void {
    this.listBound = false;
    this.onScrollerRelease();
  }

  @Builder
  private groupTabs() {
    Column() {
      ProxyGroupTabs({ browser: this.browser, active: this.active, motionEnabled: this.motionEnabled })
    }
    .padding({ bottom: 16 })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItemGroup({ header: (): void => this.groupTabs() }) {
        if (this.group.actualRetired) {
          ListItem() {
            Column({ space: 4 }) {
              Text(this.group.now)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
              Text($r('app.string.proxy_actual_retired'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontColor($r('app.color.warning'))
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
        }
        if (this.group.rowCount === 0) {
          ListItem() {
            EmptyState({
              title: $r('app.string.proxy_group_empty'),
              hint: this.group.dynamic ? $r('app.string.proxy_dynamic_offline') : $r('app.string.proxy_group_empty_hint')
            })
          }
        } else {
          LazyForEach(this.group.rows, (row: ProxyNodeRow) => {
            ListItem() {
              ProxyNodeLine({
                row: row,
                cardType: this.group.cardType,
                active: this.active,
                motionEnabled: this.motionEnabled,
                groupType: this.group.type,
                onChoose: (node: string) => this.onChoose(node),
                onTest: (node: string) => this.onTest(node)
              })
            }
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
          }, (row: ProxyNodeRow): string => row.key)
        }
      }
    }
    .width('100%')
    .height('100%')
    .safeAreaPadding({ top: this.contentInset })
    .contentStartOffset(12)
    .contentEndOffset((this.appStyle.floating ? FLOATING_BAR_INSET : 16))
    .clipContent(ContentClipMode.BOUNDARY)
    .sticky(StickyStyle.Header)
    .cachedCount(2)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .onAppear((): void => { this.listBound = true; this.onScrollerReady(); })
    .onDisAppear((): void => { this.listBound = false; this.onScrollerRelease(); })
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
      if (this.listBound) { this.onListScroll(offset, source); }
    })
  }
}
