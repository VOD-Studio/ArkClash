import { curves } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from './AppearanceState';
import { ENTER_OFFSET, enterMotion, pressEffect } from './SheetParts';

export type EmptyKind = 'empty' | 'noMatch' | 'failed';

// 插画里的三张卡从叠放处依次弹开；阻尼略低于区块入场，展开到位时带一点惯性，但不来回晃。
const FAN_SPRING: ICurve = curves.springMotion(0.62, 0.8);
const FAN_STAGGER_MS = 70;
const ART_WIDTH = 232;
const ART_HEIGHT = 156;
const ACTION_HEIGHT = 44;

interface ArtCardStyle {
  width: number;
  height: number;
  lift: number;
  scale: number;
  opacity: number;
}

const FRONT: ArtCardStyle = { width: ART_WIDTH, height: 60, lift: 0, scale: 1, opacity: 1 };
const MIDDLE: ArtCardStyle = { width: 208, height: 52, lift: -30, scale: 0.95, opacity: 0.82 };
const BACK: ArtCardStyle = { width: 184, height: 46, lift: -58, scale: 0.9, opacity: 0.56 };
// 大而重的投影在插画下方形成一团灰影，只保留贴边的轻阴影。
const FRONT_SHADOW: ShadowOptions = { radius: 6, offsetY: 2, color: '#0D000000' };
const BACK_SHADOW: ShadowOptions = { radius: 12, offsetY: 3, color: '#0A000000' };

@Builder
function noContent() {}

/**
 * 列表页的占位：空列表时是一叠卡片插画、标题、一句说明和操作入口；
 * 搜索无结果和读取失败用同一套版式，插画换成单个图标块。
 * 最前那张卡的内容和操作按钮由页面提供，版式、尺寸和动效都在这里。
 */
@ComponentV2
export struct IllustratedEmpty {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param kind: EmptyKind = 'empty';
  @Param motion: boolean = true;
  @Param @Require heading: ResourceStr;
  @Param hint: ResourceStr = '';
  // 插画最前那张卡里的内容，34 的圆形图标块、两道骨架条和一枚语义色胶囊。
  @BuilderParam front: () => void = noContent;
  // 操作按钮，用 EmptyAction；搜索无结果时不显示这一行。
  @BuilderParam actions: () => void = noContent;
  @Local private entered: boolean = false;

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  private fan(order: number): AnimateParam {
    return this.motion ? { curve: FAN_SPRING, delay: order * FAN_STAGGER_MS } : { duration: 0 };
  }

  /** 插画里的一张卡。后面两张只露出上沿，只画卡面，不画会被挡掉一半的内容。 */
  @Builder
  ArtCard(style: ArtCardStyle, order: number, front: boolean) {
    Column() {
      if (front) {
        this.front()
      }
    }
    .width(style.width)
    .height(style.height)
    .padding({ left: 13, right: 14 })
    .borderRadius(front ? 18 : 15)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .shadow(front ? FRONT_SHADOW : BACK_SHADOW)
    .scale({ x: style.scale, y: style.scale })
    .opacity(this.entered ? style.opacity : 0)
    .translate({ y: this.entered ? style.lift : (front ? ENTER_OFFSET : style.lift * 0.2) })
    .animation(this.fan(order))
  }

  // 光晕和最前那张卡一起淡入，避免卡片出现前先剩一团色块。
  @Builder
  Glow(size: number, shiftY: number) {
    Column()
      .width(size)
      .height(size)
      .offset({ x: 0, y: shiftY })
      .opacity(this.entered ? 1 : 0)
      .animation(this.fan(0))
      .radialGradient({
        center: ['50%', '50%'],
        radius: size / 2,
        colors: [[this.appStyle.palette.brandSoft, 0], [Color.Transparent, 1]]
      })
  }

  @Builder
  CardStack() {
    // 光晕比插画大，压在最前那张卡后面，超出部分不裁剪。
    Stack() {
      this.Glow(180, 8)
      Stack({ alignContent: Alignment.Bottom }) {
        this.ArtCard(BACK, 2, false)
        this.ArtCard(MIDDLE, 1, false)
        this.ArtCard(FRONT, 0, true)
      }
      .width(ART_WIDTH)
      .height(ART_HEIGHT)
    }
    .width(ART_WIDTH)
    .height(ART_HEIGHT)
    .accessibilityLevel('no')
  }

  @Builder
  Badge(icon: Resource, error: boolean) {
    Stack() {
      this.Glow(200, 0)
      Stack() {
        SymbolGlyph(icon)
          .fontSize(30)
          .fontColor([error ? $r('app.color.status_error') : this.appStyle.palette.brand])
      }
      .width(72)
      .height(72)
      .borderRadius(24)
      .backgroundColor(error ? $r('app.color.error_soft') : this.appStyle.palette.brandSoft)
      .scale({ x: this.entered ? 1 : 0.86, y: this.entered ? 1 : 0.86 })
      .opacity(this.entered ? 1 : 0)
      .animation(this.fan(0))
    }
    .width(200)
    .height(132)
    .accessibilityLevel('no')
  }

  build() {
    Column() {
      if (this.kind === 'empty') {
        this.CardStack()
      } else {
        this.Badge(this.kind === 'failed' ? $r('sys.symbol.exclamationmark_triangle') :
          $r('sys.symbol.magnifyingglass'), this.kind === 'failed')
      }
      Column({ space: 8 }) {
        Text(this.heading)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.Center)
        if (this.hint !== '') {
          Text(this.hint)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(14)
            .lineHeight(21)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: 300 })
        }
      }
      .margin({ top: this.kind === 'empty' ? 28 : 12 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : ENTER_OFFSET })
      .animation(enterMotion(this.motion, 3))
      if (this.kind !== 'noMatch') {
        Row({ space: 12 }) {
          this.actions()
        }
        .margin({ top: 28 })
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : ENTER_OFFSET })
        .animation(enterMotion(this.motion, 4))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 视觉重心略高于几何中心，下方多留一些。
    .padding({ left: 32, right: 32, bottom: 96 })
    .onAppear((): void => { this.entered = true; })
  }
}

/**
 * 占位页的胶囊按钮：主操作品牌底，次操作浅品牌底配品牌色字。
 * hasMenu 为真时点按弹出 menu 里的菜单（锚定在按钮上），不再触发 onPress。
 */
@ComponentV2
export struct EmptyAction {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param @Require label: ResourceStr;
  @Param primary: boolean = false;
  @Param motion: boolean = true;
  @Param available: boolean = true;
  @Param hasMenu: boolean = false;
  @BuilderParam menu: () => void = noContent;
  @Event onPress: () => void = (): void => {};
  @Local private menuShown: boolean = false;

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Row({ space: 6 }) {
        SymbolGlyph(this.icon)
          .fontSize(18)
          .fontColor([this.primary ? this.appStyle.palette.onBrand : this.appStyle.palette.brand])
        Text(this.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.primary ? this.appStyle.palette.onBrand : this.appStyle.palette.brand)
          .maxLines(1)
      }
    }
    .height(ACTION_HEIGHT)
    .padding({ left: 18, right: 20 })
    .backgroundColor(this.primary ? this.appStyle.palette.brand : this.appStyle.palette.brandSoft)
    .clickEffect(pressEffect(this.motion))
    .enabled(this.available)
    .bindMenu(this.menuShown, this.menu, { onDisappear: (): void => { this.menuShown = false; } })
    .onClick((): void => {
      if (this.hasMenu) {
        this.menuShown = true;
      } else {
        this.onPress();
      }
    })
  }
}
