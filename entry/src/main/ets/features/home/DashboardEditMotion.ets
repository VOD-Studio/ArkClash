import { accessibility } from '@kit.AccessibilityKit';
import { AnimatorResult } from '@kit.ArkUI';

const DASHBOARD_EDIT_SWINGS: number[] = [6, 7, 5];

@ComponentV2
export struct DashboardEditMotion {
  @Param active: boolean = false;
  @Param seed: number = 0;
  @BuilderParam @Require content: () => void;
  @Local turnDegrees: number = 0;
  @Local bobOffset: number = 0;
  @Local reduceMotion: boolean = true;
  private sway: AnimatorResult | undefined = undefined;
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

  @Monitor('active', 'reduceMotion')
  sync(): void {
    if (!this.active || this.reduceMotion) {
      this.stop();
      return;
    }
    if (this.sway !== undefined) {
      return;
    }
    this.sway = this.getUIContext().createAnimator({ duration: 3600, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    this.sway.onFrame = (progress: number): void => {
      const turn = progress * 2 * Math.PI * DASHBOARD_EDIT_SWINGS[this.seed % DASHBOARD_EDIT_SWINGS.length] +
        this.seed * 1.7;
      this.turnDegrees = Math.sin(turn) * 0.7;
      this.bobOffset = Math.cos(turn) * 1.25;
    };
    this.sway.play();
  }

  private stop(): void {
    this.sway?.cancel();
    this.sway = undefined;
    this.turnDegrees = 0;
    this.bobOffset = 0;
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .rotate({ angle: this.turnDegrees })
    .offset({ y: this.bobOffset })
  }
}
