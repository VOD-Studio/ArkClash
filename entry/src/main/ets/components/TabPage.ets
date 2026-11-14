import { LengthMetrics } from '@kit.ArkUI';
import { uiResourceText } from './ResourceText';
import {
  HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode, HdsTitleBarContentStyle, hdsMaterial,
  ScrollEffectType, TitleBarContentOptions
} from '@kit.UIDesignKit';
import { FLOATING_BAR_INSET, PAGE_GUTTER, SECTION_GAP } from './Theme';

// 对齐 Prism 的 pageToolbarHeight；标题和正文起点必须使用同一尺寸。
const TITLE_BAR_HEIGHT = 72;
// 单帧滚动超过这个距离（vp）才算换了方向，过滤手指的细微抖动。
const DIRECTION_THRESHOLD = 2;

// IMMERSIVE_GRADIENT_BLUR 默认按深色头图配白字，状态栏颜色也跟着标题走；页面是浅底，显式用正文色。
const CONTENT_STYLE: HdsTitleBarContentStyle = {
  titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
  menuStyle: { iconColor: $r('sys.color.icon_primary'), backgroundColor: $r('sys.color.comp_background_tertiary') }
};

interface TabPageHeaderState {
  title: ResourceStr;
  menus: HdsNavigationMenuItemOptions[];
  customTitle: boolean;
}

/**
 * 一级页面的骨架，按 UI Design Kit 官方写法：标题栏叠在内容上，内容滚到标题栏下面时
 * 出现沉浸式渐变模糊（IMMERSIVE_GRADIENT_BLUR），不裁剪内容。
 * 滚动方向通过 onScrollDirection 交给页面层，由它让 HdsTabs 收起页签栏、展开迷你栏。
 */
@ComponentV2
export struct TabPage {
  @Param title: ResourceStr = '';
  @Param menus: HdsNavigationMenuItemOptions[] = [];
  @Param topInset: number = 0; // 状态栏高度，vp
  @Param @Require scroller: Scroller;
  @Param listMode: boolean = false;
  @Param listSpacing: number = SECTION_GAP;
  @Param listLanes: number = 1;
  @Param listGutter: number = 0;
  @Param contentOwnsScroll: boolean = false;
  @Param customTitle: boolean = false;
  @BuilderParam titleContent: () => void = emptyContent;
  @BuilderParam content: () => void = emptyContent;
  // 滚动方向变化时回调：true = 往下看内容（页签栏该收起），false = 往回滚或回到顶部。
  @Event onScrollDirection: (down: boolean) => void = () => {};
  private down: boolean = false;

  private scrollDirection(offset: number, source: ScrollSource): void {
    if (source === ScrollSource.EDGE_EFFECT) {
      return;
    }
    let down = this.down;
    if (this.scroller.currentOffset().yOffset <= 0 && offset <= 0) {
      down = false;
    } else if (Math.abs(offset) >= DIRECTION_THRESHOLD) {
      down = offset > 0;
    }
    if (down !== this.down) {
      this.down = down;
      this.onScrollDirection(down);
    }
  }

  private menuKey(menu: HdsNavigationMenuItemOptions): string {
    const label = menu.content?.label;
    return typeof label === 'string' ? label : `${label?.id ?? -1}`;
  }

  private headerContent(title: ResourceStr, menus: HdsNavigationMenuItemOptions[],
    customTitle: boolean): TitleBarContentOptions {
    // 在 titleBar 的观察边界读取状态；旧 stackBuilder 只在延后执行时读取，未订阅参数更新。
    return {
      stackBuilderContent: {
        builder: (): void => this.Header({ title: title, menus: menus, customTitle: customTitle }),
        updated: true
      }
    };
  }

  @Builder
  Header($$: TabPageHeaderState) {
    if ($$.customTitle) {
      this.titleContent()
    } else {
      Row({ space: 8 }) {
        Text($$.title)
          .fontSize(24)
          .lineHeight(30)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Repeat($$.menus).each((menu: RepeatItem<HdsNavigationMenuItemOptions>): void => {
          Button() {
            if (menu.item.content?.icon !== undefined) {
              SymbolGlyph(menu.item.content.icon as Resource)
                .fontSize(24)
                .fontColor([$r('sys.color.icon_primary')])
            }
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.surface_block'))
          .enabled(menu.item.content?.isEnabled ?? true)
          .accessibilityText(uiResourceText(this.getUIContext(), menu.item.content?.label ?? ''))
          .onClick((): void => { menu.item.content?.action?.(); })
        }).key((menu: HdsNavigationMenuItemOptions): string => this.menuKey(menu))
      }
      .width('100%')
      .height(TITLE_BAR_HEIGHT)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
    }
  }

  build() {
    HdsNavigation() {
      if (this.contentOwnsScroll) {
        this.content()
      } else if (this.listMode) {
        List({ scroller: this.scroller, space: this.listSpacing }) {
          this.content()
        }
        .width('100%')
        .height('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
        .contentStartOffset(this.topInset + TITLE_BAR_HEIGHT + 12)
        .contentEndOffset(FLOATING_BAR_INSET)
        .cachedCount(2)
        .lanes(this.listLanes, this.listGutter)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          this.scrollDirection(offset, source);
        })
      } else {
      Scroll(this.scroller) {
        Column({ space: SECTION_GAP }) {
          this.content()
        }
        .width('100%')
        .padding({
          left: PAGE_GUTTER,
          right: PAGE_GUTTER,
          top: this.topInset + TITLE_BAR_HEIGHT + 12,
          bottom: FLOATING_BAR_INSET
        })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onWillScroll((_x: number, y: number, _state: ScrollState, source: ScrollSource) => {
        this.scrollDirection(y, source);
      })
      }
    }
    .titleBar({
      padding: { start: LengthMetrics.vp(0), end: LengthMetrics.vp(0) },
      // 窗口是沉浸式布局，标题栏要自己让开状态栏。
      avoidLayoutSafeArea: true,
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        originalStyle: { contentStyle: CONTENT_STYLE },
        scrollEffectStyle: { contentStyle: CONTENT_STYLE }
      },
      content: this.headerContent(this.title, this.menus, this.customTitle)
    })
    // 内容铺进状态栏，从状态栏和标题栏下面滚过；标题栏自己让开状态栏（avoidLayoutSafeArea）。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor(Color.Transparent)
    .bindToScrollable([this.scroller])
  }
}

@Builder
function emptyContent() {
}
