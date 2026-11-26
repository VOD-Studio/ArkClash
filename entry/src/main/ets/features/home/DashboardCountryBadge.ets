import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardLoadingRotation } from './DashboardLoadingRotation';
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

  build() {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        DashboardLoadingRotation({
          active: this.busy, visible: this.visible, motionEnabled: this.motionEnabled,
          sideLength: 48, duration: 1500
        }) {
          Shape() {
            Path().commands(DASHBOARD_CLOVER4)
              .fill(this.running ? this.appStyle.palette.brandSoft : this.appStyle.palette.tileBackground)
              .strokeWidth(0)
              .animation({ duration: this.motionEnabled && this.visible ? 300 : 0, curve: Curve.EaseOut })
          }
          .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
          .width(48)
          .height(48)
        }
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
