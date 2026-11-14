import { accessibility } from '@kit.AccessibilityKit';
import { AnimatorResult } from '@kit.ArkUI';
import { AppGlyph } from '../../components/AppGlyph';
import { DASHBOARD_CLOVER4 } from './DashboardShapePaths';

@ComponentV2
export struct DashboardCountryBadge {
  @Param countryCode: string = '';
  @Param busy: boolean = false;
  @Param running: boolean = false;
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Event onRefresh: () => void = () => {};
  @Local turnDegrees: number = 0;
  @Local reduceMotion: boolean = true;
  private turns: AnimatorResult | undefined = undefined;
  private reductionListener: (enabled: boolean) => void = (enabled: boolean): void => {
    this.reduceMotion = enabled;
    this.sync();
  };

  aboutToAppear(): void {
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.sync();
  }

  aboutToDisappear(): void {
    accessibility.offAnimationReduceStateChange(this.reductionListener);
    this.stop();
  }

  @Monitor('busy', 'visible', 'reduceMotion')
  sync(): void {
    if (!this.busy || !this.visible || this.reduceMotion) {
      this.stop();
      return;
    }
    if (this.turns !== undefined) { return; }
    this.turns = this.getUIContext().createAnimator({ duration: 1500, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 360 });
    this.turns.onFrame = (progress: number): void => { this.turnDegrees = progress; };
    this.turns.play();
  }

  private stop(): void {
    this.turns?.cancel();
    this.turns = undefined;
    this.turnDegrees = 0;
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Stack() {
        Shape() {
          Path().commands(DASHBOARD_CLOVER4).fill($r('app.color.tile_background')).strokeWidth(0)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(48)
        .height(48)
        .rotate({ angle: this.turnDegrees })
        if (this.countryCode === '') {
          AppGlyph({ name: 'proxies', iconSize: 20.16,
            iconColor: this.running ? $r('sys.color.font_primary') : $r('sys.color.font_secondary') })
        } else {
          Text(this.countryCode.toUpperCase())
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
