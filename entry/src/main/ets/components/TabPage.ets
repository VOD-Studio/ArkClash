import {
  HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode, HdsTitleBarContentStyle, hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { FLOATING_BAR_INSET, PAGE_GUTTER, SECTION_GAP } from './Theme';

// MINI 标题栏的高度。内容先让出状态栏和标题栏，往上滚时从标题栏后面经过。
const TITLE_BAR_HEIGHT = 56;

// IMMERSIVE_GRADIENT_BLUR 默认按深色头图配白字，状态栏颜色也跟着标题走；页面是浅底，显式用正文色。
const CONTENT_STYLE: HdsTitleBarContentStyle = {
  titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
  menuStyle: { iconColor: $r('sys.color.icon_primary'), backgroundColor: $r('sys.color.comp_background_tertiary') }
};

/**
 * 一级页面的骨架，按 UI Design Kit 官方写法：标题栏叠在内容上，内容滚到标题栏下面时
 * 出现沉浸式渐变模糊（IMMERSIVE_GRADIENT_BLUR），不裁剪内容。
 * scroller 同时交给 HdsTabs 绑定，页面滚动时页签栏收起、迷你栏展开。
 */
@ComponentV2
export struct TabPage {
  @Param title: ResourceStr = '';
  @Param menus: HdsNavigationMenuItemOptions[] = [];
  @Param topInset: number = 0; // 状态栏高度，vp
  @Param @Require scroller: Scroller;
  @BuilderParam content: () => void = emptyContent;

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: SECTION_GAP }) {
          this.content()
        }
        .width('100%')
        .padding({
          left: PAGE_GUTTER,
          right: PAGE_GUTTER,
          top: this.topInset + TITLE_BAR_HEIGHT + 8,
          bottom: FLOATING_BAR_INSET
        })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar({
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
      content: {
        title: { mainTitle: this.title },
        menu: { value: this.menus }
      }
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
