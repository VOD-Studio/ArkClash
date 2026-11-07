import { uiMaterial } from '@kit.ArkUI';

// 页面左右留白；卡片之间、卡片内分组之间的间距。
export const PAGE_GUTTER = 16;
export const SECTION_GAP = 12;
export const CARD_RADIUS = 16;
export const CARD_PADDING = 16;

// 悬浮页签栏盖在内容上，可滚动内容的底部要让出它的高度（栏高 + 离底距离 + 手势条）。
export const FLOATING_BAR_INSET = 112;

/** 普通卡片：不透明底色加一层轻阴影，材质只留给页签栏、标题栏和弹层。 */
export class CardModifier implements AttributeModifier<ColumnAttribute> {
  applyNormalAttribute(instance: ColumnAttribute): void {
    instance
      .width('100%')
      .padding(CARD_PADDING)
      .borderRadius(CARD_RADIUS)
      .backgroundColor($r('app.color.card_background'))
      .shadow({ radius: 24, offsetY: 4, color: '#0D000000' });
  }
}

export const CARD: CardModifier = new CardModifier();

/** 沉浸光感材质。设备不支持时系统自动退化成背景色、描边和阴影的组合。 */
export function sheetMaterial(): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK });
}
