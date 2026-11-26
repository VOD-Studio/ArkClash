import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { DASHBOARD_CLOVER4 } from './DashboardShapePaths';

@ComponentV2
export struct DashboardCountryBadge {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param countryCode: string = '';
  @Param busy: boolean = false;
  @Param running: boolean = false;
  @Param visible: boolean = true;
  @Param motionEnabled: boolean = false;
  @Param interactive: boolean = true;
  @Event onRefresh: () => void = () => {};
  @Local private pulsing: boolean = false;
  private appeared: boolean = false;

  @Monitor('busy', 'visible', 'motionEnabled')
  syncPulse(): void {
    this.pulsing = this.appeared && this.busy && this.visible && this.motionEnabled;
  }

  build() {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        Shape() {
          Path().commands(DASHBOARD_CLOVER4)
            .fill(this.running ? this.appStyle.palette.brandSoft : this.appStyle.palette.tileBackground)
            .strokeWidth(0)
            .animation({ duration: this.motionEnabled && this.visible ? 300 : 0, curve: Curve.EaseOut })
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(48)
        .height(48)
        .scale({ x: this.pulsing ? 1.05 : 1, y: this.pulsing ? 1.05 : 1 })
        .opacity(this.pulsing ? 0.62 : 1)
        .animation({
          duration: this.pulsing ? 640 : (this.motionEnabled && this.visible ? 200 : 0),
          curve: this.pulsing ? Curve.EaseInOut : Curve.EaseOut,
          iterations: this.pulsing ? -1 : 1,
          playMode: this.pulsing ? PlayMode.Alternate : PlayMode.Normal
        })
        if (this.countryCode === '') {
          AppGlyph({ name: 'proxies', iconSize: 20.16,
            iconColor: this.running ? this.appStyle.palette.brand : $r('sys.color.font_secondary') })
        } else {
          Text(this.countryCode.toUpperCase())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontWeight(600)
            .letterSpacing(0.52)
            .fontColor(this.running ? this.appStyle.palette.brand : $r('sys.color.font_secondary'))
            .maxLines(1)
        }
      }
      .width(48)
      .height(48)
      .onAppear((): void => {
        this.appeared = true;
        this.syncPulse();
      })
      .onDisAppear((): void => {
        this.appeared = false;
        this.pulsing = false;
      })
    }
    .width(48)
    .height(48)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(this.interactive && !this.busy)
    .accessibilityText($r('app.string.dash_retry_exit'))
    .onClick((): void => { this.onRefresh(); })
  }
}
