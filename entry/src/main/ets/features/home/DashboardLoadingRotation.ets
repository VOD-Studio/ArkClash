@ComponentV2
export struct DashboardLoadingRotation {
  @Param active: boolean = false;
  @Param visible: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param sideLength: number = 84;
  @Param duration: number = 1800;
  @BuilderParam @Require content: () => void;
  @Local looping: boolean = false;
  private appeared: boolean = false;

  @Monitor('active', 'visible', 'motionEnabled')
  syncAnimation(): void {
    this.looping = this.appeared && this.active && this.visible && this.motionEnabled;
  }

  build() {
    Stack() {
      this.content()
    }
    .width(this.sideLength)
    .height(this.sideLength)
    .rotate({ angle: this.looping ? 360 : 0 })
    .animation({
      duration: this.looping ? this.duration : 0,
      curve: Curve.Linear,
      iterations: this.looping ? -1 : 1,
      playMode: PlayMode.Normal
    })
    .hitTestBehavior(HitTestMode.None)
    .onAppear((): void => {
      this.appeared = true;
      this.syncAnimation();
    })
    .onDisAppear((): void => {
      this.appeared = false;
      this.syncAnimation();
    })
  }
}
