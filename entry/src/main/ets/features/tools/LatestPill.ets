import { AppGlyph } from '../../components/AppGlyph';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';

// 诊断列表暂停跟随后浮在底部的「回到最新」胶囊，日志和 DNS 页共用。
// 放在 alignContent 为 Bottom 的 Stack 末尾，压在列表和空状态上方；显隐由 shown 控制，
// 转场挂在组件内部的 Button 上，外面不要再包 if。
@ComponentV2
export struct LatestPill {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param shown: boolean = false;
  @Param label: ResourceStr = '';
  @Param inspectorId: string = '';
  @Param reduceMotion: boolean = true;
  @Event onPress: () => void = () => {};
  private readonly pillTransition: TransitionEffect = TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: 180, curve: Curve.EaseOut }),
    TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 8 }))
      .animation({ duration: 140, curve: Curve.EaseIn })
  );

  build() {
    if (this.shown) {
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 6 }) {
          AppGlyph({ name: 'arrowUp', iconSize: 15, iconColor: this.appStyle.palette.onBrand })
          Text(this.label)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.appStyle.palette.onBrand)
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      }
      .backgroundColor(this.appStyle.palette.brand)
      .shadow({ radius: 16, offsetY: 4, color: $r('app.color.dashboard_shadow') })
      .margin({ bottom: 20 })
      .id(this.inspectorId)
      .accessibilityDescription($r('app.string.diagnostics_paused'))
      .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.pillTransition)
      .onClick((): void => this.onPress())
    }
  }
}
