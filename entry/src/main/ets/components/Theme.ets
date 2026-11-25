import { hdsMaterial, HdsTitleBarContentStyle, ScrollEffectType, SystemMaterialParams, TitleBarStyleOptions } from '@kit.UIDesignKit';
import { AppearanceGlass } from './AppearanceState';

// 页面左右留白；卡片之间、卡片内分组之间的间距。
export const PAGE_GUTTER = 16;
export const HEADER_GAP = 8;
export const HEADER_ACTION_SIZE = 40;
export const HEADER_ICON_SIZE = 24;
export const TAB_HEADER_HEIGHT = 72;
export const TAB_TITLE_SIZE = 24;
export const TAB_TITLE_LINE_HEIGHT = 30;
export const COMPACT_TITLE_SIZE = 20;
export const COMPACT_TITLE_LINE_HEIGHT = 26;
export const SHEET_HEADER_HEIGHT = 56;
export const SECTION_GAP = 12;
export const CARD_RADIUS = 16;
export const CARD_PADDING = 16;

// 悬浮页签栏盖在内容上，可滚动内容的底部要让出它的高度（栏高 + 离底距离 + 手势条）。
export const FLOATING_BAR_INSET = 112;

/** 阴影使用原生绘制边界；内容圆角裁剪只放在卡片内部，不能包住阴影层。 */
export class CardModifier implements AttributeModifier<ColumnAttribute> {
  private readonly radius: number;
  private readonly horizontalPadding: number;
  private readonly verticalPadding: number;
  private readonly shadowColor: ResourceColor;

  constructor(radius: number = CARD_RADIUS, horizontalPadding: number = CARD_PADDING,
    verticalPadding: number = CARD_PADDING, shadowColor: ResourceColor = '#0D000000') {
    this.radius = radius;
    this.horizontalPadding = horizontalPadding;
    this.verticalPadding = verticalPadding;
    this.shadowColor = shadowColor;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    instance
      .width('100%')
      .padding({ left: this.horizontalPadding, right: this.horizontalPadding,
        top: this.verticalPadding, bottom: this.verticalPadding })
      .borderRadius(this.radius)
      .shadow({ radius: 24, offsetY: 4, color: this.shadowColor });
  }
}

export class HeaderActionModifier implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(instance: ButtonAttribute): void {
    instance
      .width(HEADER_ACTION_SIZE)
      .height(HEADER_ACTION_SIZE)
      .padding(0)
      .borderRadius(20)
      .buttonStyle(ButtonStyleMode.NORMAL)
  }
}

export const CARD: CardModifier = new CardModifier();
export const DASHBOARD_CARD: CardModifier = new CardModifier(34, 20, 18, $r('app.color.dashboard_shadow'));
export const HEADER_ACTION: HeaderActionModifier = new HeaderActionModifier();

const HDS_NO_GLASS: SystemMaterialParams = { materialType: hdsMaterial.MaterialType.NONE };
const HDS_STANDARD_GLASS: SystemMaterialParams = {
  materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
};
const HDS_ULTRA_GLASS: SystemMaterialParams = {
  materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
};

export function hdsGlass(glass: AppearanceGlass): SystemMaterialParams {
  if (glass === 'none') { return HDS_NO_GLASS; }
  return glass === 'ultra' ? HDS_ULTRA_GLASS : HDS_STANDARD_GLASS;
}

const TITLE_CONTENT_STYLE: HdsTitleBarContentStyle = {
  titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
  backIconStyle: { iconColor: $r('sys.color.icon_primary'), backgroundColor: $r('sys.color.comp_background_tertiary') },
  menuStyle: { iconColor: $r('sys.color.icon_primary'), backgroundColor: $r('sys.color.comp_background_tertiary') }
};

export function immersiveTitleStyle(glass: AppearanceGlass): TitleBarStyleOptions {
  return {
    scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR },
    systemMaterialEffect: hdsGlass(glass),
    originalStyle: { contentStyle: TITLE_CONTENT_STYLE },
    scrollEffectStyle: { contentStyle: TITLE_CONTENT_STYLE }
  };
}
