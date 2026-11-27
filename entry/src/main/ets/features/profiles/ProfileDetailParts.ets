import { curves } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';

export type DetailTone = 'brand' | 'neutral' | 'error';

export const DETAIL_CARD_RADIUS = 24;
const METER_HEIGHT = 10;
// 流量条比区块入场慢一拍、阻尼略低，伸到目标时有轻微的惯性感但不回弹。
const METER_SPRING: ICurve = curves.springMotion(0.75, 0.88);
const CHIP_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
  .animation({ curve: curves.responsiveSpringMotion() });

/** 详情顶部的状态胶囊。显隐由 shown 控制，转场挂在内部节点上，调用方不要再包 if。 */
@ComponentV2
export struct DetailChip {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param shown: boolean = true;
  @Param label: ResourceStr = '';
  @Param icon: Resource | undefined = undefined;
  @Param tone: DetailTone = 'neutral';
  @Param dot: boolean = false;
  @Param busy: boolean = false;
  @Param motion: boolean = true;

  private ink(): ResourceColor {
    if (this.tone === 'brand') { return this.appStyle.palette.brand; }
    if (this.tone === 'error') { return $r('app.color.status_error'); }
    return $r('sys.color.font_secondary');
  }

  // 品牌色在 profileExpiryTonal 上的小字对比度由调色板保证，换衬底前先核对 AppearancePalette。
  private fill(): ResourceColor {
    if (this.tone === 'brand') { return this.appStyle.palette.profileExpiryTonal; }
    if (this.tone === 'error') { return $r('app.color.profile_expiry_error_tonal'); }
    return this.appStyle.palette.track;
  }

  build() {
    if (this.shown) {
      Row({ space: 5 }) {
        if (this.busy) {
          LoadingProgress().width(14).height(14).color(this.ink())
        } else if (this.dot) {
          Circle({ width: 6, height: 6 }).fill(this.ink())
        } else if (this.icon !== undefined) {
          SymbolGlyph(this.icon).fontSize(13).fontColor([this.ink()])
        }
        Text(this.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .lineHeight(16)
          .fontWeight(600)
          .fontColor(this.ink())
          .maxLines(1)
      }
      .height(24)
      .padding({ left: 9, right: 10 })
      .margin({ right: 6, top: 6 })
      .borderRadius(12)
      .backgroundColor(this.fill())
      .transition(this.motion ? CHIP_TRANSITION : TransitionEffect.IDENTITY)
    }
  }
}

/** 数字磁贴。loading 时显示与数字同尺寸的骨架，数据到达后淡入；之后的数值变化用翻牌过渡。 */
@ComponentV2
export struct DetailStat {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param figure: ResourceStr = '';
  @Param unit: ResourceStr = '';
  @Param label: ResourceStr = '';
  @Param loading: boolean = false;
  @Param tone: ResourceColor = $r('sys.color.font_primary');
  @Param motion: boolean = true;
  private readonly numeric: NumericTextTransition =
    new NumericTextTransition({ flipDirection: FlipDirection.UP, enableBlur: true });
  private readonly reveal: TransitionEffect =
    TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut });

  build() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.Start }) {
        if (this.loading) {
          Row()
            .width(44)
            .height(20)
            .borderRadius(6)
            .backgroundColor(this.appStyle.palette.track)
            .transition(this.motion ? this.reveal : TransitionEffect.IDENTITY)
        } else {
          Flex({ alignItems: ItemAlign.Baseline }) {
            Text(this.figure)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(24)
              .lineHeight(30)
              .fontWeight(700)
              .fontFeature('"tnum" on')
              .fontColor(this.tone)
              .maxLines(1)
              .contentTransition(this.motion ? this.numeric : undefined)
            if (this.unit !== '') {
              Text(this.unit)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(13)
                .fontWeight(600)
                .fontColor(this.tone)
                .margin({ left: 3 })
                .maxLines(1)
            }
          }
          .width('100%')
          .transition(this.motion ? this.reveal : TransitionEffect.IDENTITY)
        }
      }
      .width('100%')
      .height(30)
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(12)
        .lineHeight(16)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 12, top: 14, bottom: 14 })
    .borderRadius(20)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }
}

/**
 * 流量条。shown 为 false 时停在 0，置 true 后以弹簧伸到 share；share 变化时同样过渡。
 * 宽度来自实测轨道宽度，避免百分比宽度在首帧被当成终值直接画出。
 */
@ComponentV2
export struct DetailMeter {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param share: number = 0; // 0–1
  @Param color: ResourceColor = $r('sys.color.font_primary');
  @Param shown: boolean = false;
  @Param motion: boolean = true;
  @Param delayMs: number = 0;
  @Local trackWidth: number = 0;

  @Computed
  get fillWidth(): number {
    if (!this.shown || this.trackWidth <= 0 || this.share <= 0) { return 0; }
    // 份额很小时至少画出一个圆点，用户能看出“已用了一点”而不是零。
    return Math.max(METER_HEIGHT, this.trackWidth * Math.min(1, this.share));
  }

  private fillAnimation(): AnimateParam {
    return this.motion ? { curve: METER_SPRING, delay: this.delayMs } : { duration: 0 };
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width(this.fillWidth)
        .height(METER_HEIGHT)
        .borderRadius(METER_HEIGHT / 2)
        .backgroundColor(this.color)
        .animation(this.fillAnimation())
    }
    .width('100%')
    .height(METER_HEIGHT)
    .borderRadius(METER_HEIGHT / 2)
    .backgroundColor(this.appStyle.palette.track)
    .clip(true)
    .onAreaChange((_previous: Area, current: Area): void => { this.trackWidth = Number(current.width); })
  }
}

/** 信息卡里只读的一行：图标、名称、右对齐的值。 */
@ComponentV2
export struct DetailInfoRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param tone: ResourceColor = $r('sys.color.font_secondary');

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.icon).fontSize(20).fontColor([$r('sys.color.font_secondary')])
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(15)
        .lineHeight(20)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
      Text(this.value)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .lineHeight(20)
        .fontFeature('"tnum" on')
        .fontColor(this.tone)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
  }
}

/** 操作卡里的一行：品牌色圆形图标、标题、箭头；busy 时箭头换成转圈并禁用点击。 */
@ComponentV2
export struct DetailAction {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param label: ResourceStr = '';
  @Param busy: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(this.icon).fontSize(18).fontColor([this.appStyle.palette.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .lineHeight(22)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.busy) {
        LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand)
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .width('100%')
    .height(60)
    .padding({ left: 14, right: 16 })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.interactive_pressed')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .enabled(!this.busy)
    .onClick((): void => this.onTap())
  }
}
