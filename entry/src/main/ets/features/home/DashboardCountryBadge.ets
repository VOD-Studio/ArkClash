import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { DASHBOARD_CLOVER4 } from './DashboardShapePaths';

@ComponentV2
export struct DashboardCountryBadge {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param countryCode: string = '';
  @Param busy: boolean = false;
  @Param running: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param interactive: boolean = true;
  @Event onRefresh: () => void = () => {};
  @Local spinning: boolean = false;

  @Monitor('busy', 'motionEnabled')
  sync(): void {
    this.spinning = this.busy && this.motionEnabled;
  }

  build() {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        Shape() {
          Path().commands(DASHBOARD_CLOVER4).fill(this.appStyle.palette.tileBackground).strokeWidth(0)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(48)
        .height(48)
        .rotate({ angle: this.spinning ? 360 : 0 })
        .animation({ duration: this.spinning ? 1500 : 0, curve: Curve.Linear,
          iterations: this.spinning ? -1 : 1 })
        .onAppear((): void => { this.sync(); })
        if (this.countryCode === '') {
          AppGlyph({ name: 'proxies', iconSize: 20.16,
            iconColor: this.running ? $r('sys.color.font_primary') : $r('sys.color.font_secondary') })
        } else {
          Text(this.countryCode.toUpperCase())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontWeight(600)
            .letterSpacing(0.52)
            .fontColor(this.running ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .maxLines(1)
        }
      }
      .width(48)
      .height(48)
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
