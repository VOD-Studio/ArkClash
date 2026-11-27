import { curves } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { RULE_ENTER_OFFSET, ruleEnter, rulePressEffect } from './AddedRuleSheetParts';

export type AddedRulesEmptyKind = 'empty' | 'noMatch' | 'failed';

// 插画里的三张规则卡从叠放处依次弹开；阻尼略低于区块入场，展开到位时带一点惯性，但不来回晃。
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
const FRONT_SHADOW: ShadowOptions = { radius: 28, offsetY: 10, color: '#16000000' };
const BACK_SHADOW: ShadowOptions = { radius: 12, offsetY: 3, color: '#0A000000' };

/**
 * 附加规则页的占位：空列表时是一叠规则卡插画、一句说明和「添加规则」「快捷操作」两个入口；
 * 搜索无结果和读取失败用同一套版式，换成单个图标块。
 */
@ComponentV2
export struct AddedRulesEmpty {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param kind: AddedRulesEmptyKind = 'empty';
  @Param motion: boolean = true;
  @Param available: boolean = true;
  @Event onAdd: () => void = (): void => {};
  @Event onPresets: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};
  @Local private entered: boolean = false;

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  private fan(order: number): AnimateParam {
    return this.motion ? { curve: FAN_SPRING, delay: order * FAN_STAGGER_MS } : { duration: 0 };
  }

  @Builder
  Bar(width: number, height: number, color: ResourceColor) {
    Row().width(width).height(height).borderRadius(height / 2).backgroundColor(color)
  }

  /** 插画最前面的规则卡：分流图标、两道文字骨架和绿色的直连胶囊。 */
  @Builder
  FrontContent() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_triangle_divide')).fontSize(18).fontColor([this.appStyle.palette.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 6 }) {
        this.Bar(86, 8, this.appStyle.palette.track)
        this.Bar(52, 6, this.appStyle.palette.divider)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Row() {
        Circle({ width: 6, height: 6 }).fill($r('app.color.status_connected'))
      }
      .width(40)
      .height(20)
      .borderRadius(10)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.success_soft'))
    }
    .width('100%')
    .height('100%')
  }

  /** 插画里的一张规则卡。后面两张只露出上沿，只画卡面，不画会被挡掉一半的内容。 */
  @Builder
  ArtCard(style: ArtCardStyle, order: number, front: boolean) {
    Column() {
      if (front) {
        this.FrontContent()
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
    .translate({ y: this.entered ? style.lift : (front ? RULE_ENTER_OFFSET : style.lift * 0.2) })
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
  RuleStack() {
    // 光晕比插画大，压在最前那张卡后面，超出部分不裁剪。
    Stack() {
      this.Glow(240, 28)
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

  @Builder
  ActionButton(icon: Resource, label: Resource, primary: boolean, action: () => void) {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([primary ? this.appStyle.palette.onBrand : this.appStyle.palette.brand])
        Text(label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(primary ? this.appStyle.palette.onBrand : this.appStyle.palette.brand)
          .maxLines(1)
      }
    }
    .height(ACTION_HEIGHT)
    .padding({ left: 18, right: 20 })
    .backgroundColor(primary ? this.appStyle.palette.brand : this.appStyle.palette.brandSoft)
    .clickEffect(rulePressEffect(this.motion))
    .enabled(this.available)
    .onClick((): void => action())
  }

  private title(): Resource {
    if (this.kind === 'failed') { return $r('app.string.added_rules_load_failed'); }
    if (this.kind === 'noMatch') { return $r('app.string.added_rules_no_matches'); }
    return $r('app.string.added_rules_empty_title');
  }

  build() {
    Column() {
      if (this.kind === 'empty') {
        this.RuleStack()
      } else {
        this.Badge(this.kind === 'failed' ? $r('sys.symbol.exclamationmark_triangle') :
          $r('sys.symbol.magnifyingglass'), this.kind === 'failed')
      }
      Column({ space: 8 }) {
        Text(this.title())
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.Center)
        if (this.kind === 'empty') {
          Text($r('app.string.added_rules_empty_hint'))
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
      .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
      .animation(ruleEnter(this.motion, 3))
      if (this.kind !== 'noMatch') {
        Row({ space: 12 }) {
          if (this.kind === 'empty') {
            this.ActionButton($r('sys.symbol.plus'), $r('app.string.added_rules_add'), true, (): void => this.onAdd())
            this.ActionButton($r('sys.symbol.bolt'), $r('app.string.added_rules_presets'), false,
              (): void => this.onPresets())
          } else {
            this.ActionButton($r('sys.symbol.arrow_clockwise'), $r('app.string.dns_override_retry'), false,
              (): void => this.onRetry())
          }
        }
        .margin({ top: 28 })
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
        .animation(ruleEnter(this.motion, 4))
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
