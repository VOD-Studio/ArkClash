import { UIUtils } from '@kit.ArkUI';

@ComponentV2
export struct DashboardLoadingRotation {
  @Param active: boolean = false;
  @Param visible: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param reverse: boolean = false;
  @Param sideLength: number = 84;
  @Param duration: number = 1800;
  @BuilderParam @Require content: () => void;
  @Local angle: number = 0;
  private appeared: boolean = false;
  private spinning: boolean = false;
  private generation: number = 0;

  @Monitor('active', 'visible', 'motionEnabled')
  syncAnimation(): void {
    const shouldSpin = this.appeared && this.active && this.visible && this.motionEnabled;
    if (shouldSpin === this.spinning) {
      return;
    }
    this.spinning = shouldSpin;
    const generation = ++this.generation;
    const ui = this.getUIContext();
    const fullTurn = this.reverse ? -360 : 360;
    const settleTurn = this.reverse ? -360.01 : 360.01;
    if (shouldSpin) {
      ui.animateTo({ duration: 0 }, (): void => {
        UIUtils.applySync<void>((): void => { this.angle = 0; });
      });
      ui.animateTo({
        duration: this.duration,
        curve: Curve.Linear,
        iterations: -1,
        playMode: PlayMode.Normal
      }, (): void => {
        UIUtils.applySync<void>((): void => { this.angle = fullTurn; });
      });
      return;
    }
    if (!this.appeared || !this.visible || !this.motionEnabled) {
      ui.animateTo({ duration: 0 }, (): void => {
        UIUtils.applySync<void>((): void => { this.angle = 0; });
      });
      return;
    }
    // 停止时顺着旋转方向减速滑行至整圈同位再静默归零，避免 0ms 瞬移回弹。
    ui.animateTo({
      duration: 420,
      curve: Curve.EaseOut,
      iterations: 1,
      onFinish: (): void => {
        if (generation === this.generation && !this.spinning && this.appeared) {
          this.getUIContext().animateTo({ duration: 0 }, (): void => {
            UIUtils.applySync<void>((): void => { this.angle = 0; });
          });
        }
      }
    }, (): void => {
      UIUtils.applySync<void>((): void => { this.angle = settleTurn; });
    });
  }

  build() {
    Stack() {
      this.content()
    }
    .width(this.sideLength)
    .height(this.sideLength)
    .rotate({ angle: this.angle })
    .hitTestBehavior(HitTestMode.None)
    .onAppear((): void => {
      this.appeared = true;
      this.syncAnimation();
    })
    .onDisAppear((): void => {
      this.appeared = false;
      this.spinning = false;
      this.generation++;
      this.angle = 0;
    })
  }
}
