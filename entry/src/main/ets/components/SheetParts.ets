import { curves } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from './AppearanceState';
import { HEADER_ACTION } from './Theme';

// 抽屉、空状态共用的视觉部件和动效参数，版式与取值见 docs/agents/ui-patterns.md。
export const SHEET_CARD_RADIUS = 20;
export const SHEET_ACTION_HEIGHT = 48;
export const SHEET_ROW_HEIGHT = 72;
export const SHEET_TILE_SIZE = 40;
// 卡片内文字左缘：左内边距 16 + 图标块 40 + 间距 12，分隔线从这里起。
export const SHEET_TEXT_INSET = 68;

// 区块依次上浮淡入，和抽屉上滑大致同时结束；间隔取到能分出先后、又不拖慢整体的值。
const ENTER_STAGGER_MS = 40;
export const ENTER_OFFSET = 16;
const ENTER_SPRING: ICurve = curves.springMotion(0.5, 0.92);
// 选择、展开这类即时反馈用响应式弹簧：跟手、不拖尾，中途反向时从当前值接着走。
export const SETTLE_SPRING: ICurve = curves.responsiveSpringMotion(0.36, 0.86);
// 新区块晚一拍再浮现，先让下方内容让出位置，避免和正在下移的按钮叠在一起；移除时直接淡出。
const SECTION_APPEAR_DELAY_MS = 70;
const SECTION_TRANSITION: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: -8 }))
    .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }))
    .animation({ curve: SETTLE_SPRING, delay: SECTION_APPEAR_DELAY_MS }),
  TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.Sharp })
);
const PRESS_EFFECT: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.95 };

export type Tone = 'brand' | 'success' | 'error' | 'neutral';

/** 第 index 个区块的入场动画；减弱动态时零时长，首帧即终态。 */
export function enterMotion(motion: boolean, index: number): AnimateParam {
  return motion ? { curve: ENTER_SPRING, delay: index * ENTER_STAGGER_MS } : { duration: 0 };
}

export function sectionTransition(motion: boolean): TransitionEffect {
  return motion ? SECTION_TRANSITION : TransitionEffect.IDENTITY;
}

export function pressEffect(motion: boolean): ClickEffect | null {
  return motion ? PRESS_EFFECT : null;
}

/** 抽屉标题区：品牌色图标块、标题、可选说明和关闭按钮；关闭交给调用方做脏数据保护。 */
@ComponentV2
export struct SheetHeader {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param @Require heading: ResourceStr;
  @Param subheading: ResourceStr = '';
  @Param closable: boolean = true;
  @Event onClose: () => void = (): void => {};

  build() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(this.icon).fontSize(24).fontColor([this.appStyle.palette.brand])
      }
      .width(48)
      .height(48)
      .borderRadius(16)
      .backgroundColor(this.appStyle.palette.profileExpiryTonal)
      Column({ space: 2 }) {
        Text(this.heading)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subheading !== '') {
          Text(this.subheading)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.action_close'))
      .enabled(this.closable)
      .onClick((): void => this.onClose())
    }
    .width('100%')
  }
}

/**
 * 通栏主按钮；进行中在按钮内转圈，不另加提示。
 * danger 用于删除这类不可撤销的操作：浅红底配红字，醒目但不刺眼。
 */
@ComponentV2
export struct PrimaryButton {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: ResourceStr;
  @Param busyLabel: ResourceStr = $r('app.string.access_control_saving');
  @Param danger: boolean = false;
  @Param busy: boolean = false;
  @Param available: boolean = true;
  @Event onPress: () => void = (): void => {};

  private ink(): ResourceColor {
    return this.danger ? $r('app.color.status_error') : this.appStyle.palette.onBrand;
  }

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Row({ space: 8 }) {
        if (this.busy) {
          LoadingProgress().width(20).height(20).color(this.ink())
        }
        Text(this.busy ? this.busyLabel : this.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.ink())
          .maxLines(1)
      }
    }
    .width('100%')
    .height(SHEET_ACTION_HEIGHT)
    .backgroundColor(this.danger ? $r('app.color.profile_expiry_error_tonal') : this.appStyle.palette.brand)
    // 进行中保持实色显示转圈，只是不再响应点击。
    .enabled(this.available || this.busy)
    .onClick((): void => {
      if (!this.busy) {
        this.onPress();
      }
    })
  }
}

/** 次级胶囊按钮：浅底、文字着色，错误语义只染文字不铺红底。 */
@ComponentV2
export struct SecondaryButton {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: ResourceStr;
  @Param danger: boolean = false;
  @Param available: boolean = true;
  @Event onPress: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL }) {
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontWeight(500)
        .fontColor(this.danger ? $r('app.color.status_error') : $r('sys.color.font_primary'))
        .maxLines(1)
    }
    .width('100%')
    .height(SHEET_ACTION_HEIGHT)
    .enabled(this.available)
    .onClick((): void => this.onPress())
  }
}

/** 一行提示：错误放进浅红衬底卡，普通提示用浅色衬底。 */
@ComponentV2
export struct NoteCard {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param @Require text: ResourceStr;
  @Param error: boolean = false;

  build() {
    Row({ space: 10 }) {
      SymbolGlyph(this.icon)
        .fontSize(18)
        .fontColor([this.error ? $r('app.color.status_error') : $r('sys.color.font_secondary')])
      Text(this.text)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .lineHeight(20)
        .fontColor(this.error ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(14)
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(this.error ? $r('app.color.profile_expiry_error_tonal') : this.appStyle.palette.cardBackground)
  }
}

/**
 * 可选胶囊。选中只换底色和字色，宽度不变，换行布局不会因为点选而跳动；
 * 前导是语义色圆点或图标，选中后统一变成品牌底上的反色。
 */
@ComponentV2
export struct ChoiceChip {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: ResourceStr;
  @Param selected: boolean = false;
  @Param tone: Tone = 'neutral';
  @Param icon: Resource | undefined = undefined;
  @Param mono: boolean = true;
  @Param motion: boolean = true;
  @Event onTap: () => void = (): void => {};

  private ink(): ResourceColor {
    if (this.selected) { return this.appStyle.palette.onBrand; }
    if (this.tone === 'success') { return $r('app.color.status_connected'); }
    if (this.tone === 'error') { return $r('app.color.status_error'); }
    if (this.tone === 'brand') { return this.appStyle.palette.brand; }
    return $r('sys.color.font_tertiary');
  }

  build() {
    Row({ space: 7 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon).fontSize(14).fontColor([this.ink()])
      } else {
        // 用背景色画圆点：Circle 的 fill 不参与属性动画，选中切换时会跳色。
        Row()
          .width(7)
          .height(7)
          .borderRadius(3.5)
          .backgroundColor(this.ink())
          .animation(this.motion ? { curve: SETTLE_SPRING } : { duration: 0 })
      }
      Text(this.label)
        .fontFamily(this.mono ? 'monospace' : this.appStyle.fontFamily)
        .fontSize(14)
        .fontWeight(this.mono ? 600 : 500)
        .fontColor(this.selected ? this.appStyle.palette.onBrand : $r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .animation(this.motion ? { curve: SETTLE_SPRING } : { duration: 0 })
    }
    .height(36)
    .constraintSize({ maxWidth: '100%' })
    .padding({ left: 12, right: 14 })
    .borderRadius(18)
    .backgroundColor(this.selected ? this.appStyle.palette.brand : this.appStyle.palette.tileBackground)
    .animation(this.motion ? { curve: SETTLE_SPRING } : { duration: 0 })
    .clickEffect(pressEffect(this.motion))
    .accessibilityGroup(true)
    .accessibilitySelected(this.selected)
    .onClick((): void => this.onTap())
  }
}
