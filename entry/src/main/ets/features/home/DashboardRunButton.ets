import { curves } from '@kit.ArkUI';
import { uiResourceText } from '../../components/ResourceText';
import { DASHBOARD_COOKIE9 } from './DashboardShapePaths';

const START_CURVE = curves.cubicBezierCurve(0.34, 1.56, 0.64, 1);

@ComponentV2
export struct DashboardRunButton {
  @Param running: boolean = false;
  @Param busy: boolean = false;
  @Param interactive: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param visible: boolean = false;
  @Param label: ResourceStr = '';
  @Event onToggle: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        Shape() {
          Path().commands(DASHBOARD_COOKIE9)
            .fill(this.interactive || this.running ? $r('app.color.brand') : $r('app.color.tile_background'))
            .strokeWidth(0)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(88)
        .height(88)
        .rotate({ angle: this.running ? 40 : 0 })
        .animation({ duration: this.motionEnabled ? 450 : 0, curve: this.running ? START_CURVE : Curve.EaseIn })
        Circle({ width: 88, height: 88 })
          .fill(this.interactive || this.running ? $r('app.color.brand') : $r('app.color.tile_background'))
          .strokeWidth(0)
          .scale({ x: this.running ? 0.84 : 1, y: this.running ? 0.84 : 1 })
          .animation({ duration: this.motionEnabled ? 450 : 0, curve: this.running ? START_CURVE : Curve.EaseIn })
        if (this.busy) {
          LoadingProgress().width(30).height(30).color(Color.White).enableLoading(this.visible)
        } else {
          SymbolGlyph(this.running ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
            .fontSize(30)
            .fontColor([this.interactive || this.running ? Color.White : $r('sys.color.font_secondary')])
            .width(30)
            .height(30)
            .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), this.motionEnabled)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(88)
      .height(88)
    }
    .width(88)
    .height(88)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(this.interactive)
    .accessibilityText(uiResourceText(this.getUIContext(), this.label))
    .onClick((): void => { this.onToggle(); })
  }
}
