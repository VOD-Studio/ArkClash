import { uiMaterial } from '@kit.ArkUI';
import { FlClashDashboardShadow } from './FlClashDashboardShadow';

// 页面左右留白；卡片之间、卡片内分组之间的间距。
export const PAGE_GUTTER = 16;
export const SECTION_GAP = 12;
export const CARD_RADIUS = 16;
export const CARD_PADDING = 16;

// 悬浮页签栏盖在内容上，可滚动内容的底部要让出它的高度（栏高 + 离底距离 + 手势条）。
export const FLOATING_BAR_INSET = 112;

@Builder
export function dashboardCardShadow(): void {
  FlClashDashboardShadow()
}

/** 普通卡片默认保留轻阴影；仪表盘阴影走独立背景，材质只留给悬浮界面。 */
export class CardModifier implements AttributeModifier<ColumnAttribute> {
  private readonly radius: number;
  private readonly horizontalPadding: number;
  private readonly verticalPadding: number;
  private readonly dropShadow: boolean;

  constructor(radius: number = CARD_RADIUS, horizontalPadding: number = CARD_PADDING,
    verticalPadding: number = CARD_PADDING, dropShadow: boolean = true) {
    this.radius = radius;
    this.horizontalPadding = horizontalPadding;
    this.verticalPadding = verticalPadding;
    this.dropShadow = dropShadow;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    instance
      .width('100%')
      .padding({ left: this.horizontalPadding, right: this.horizontalPadding,
        top: this.verticalPadding, bottom: this.verticalPadding })
      .borderRadius(this.radius)
      .backgroundColor($r('app.color.card_background'));
    if (this.dropShadow) {
      instance.shadow({ radius: 24, offsetY: 4, color: '#0D000000' });
    }
  }
}

export const CARD: CardModifier = new CardModifier();
export const DASHBOARD_CARD: CardModifier = new CardModifier(34, 20, 18, false);

/** 沉浸光感材质。设备不支持时系统自动退化成背景色、描边和阴影的组合。 */
export function sheetMaterial(): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK });
}
