@ComponentV2
export struct DashboardEditMotion {
  @Param active: boolean = false;
  @Param seed: number = 0;
  @Param reduceMotion: boolean = true;
  @BuilderParam @Require content: () => void;
  @Local angle: number = 0;
  @Local lift: number = 0;
  private appeared: boolean = false;
  private looping: boolean = false;

  @Monitor('active', 'reduceMotion')
  syncAnimation(): void {
    const looping = this.active && !this.reduceMotion;
    if (!this.appeared || looping === this.looping) {
      return;
    }
    this.looping = looping;
    // 用零时长闭包改回原位，终止已提交的无限动画，而不是只替换下一次动画参数。
    this.getUIContext().animateToImmediately({
      duration: looping ? 360 + this.seed % 3 * 60 : 0,
      curve: Curve.EaseInOut,
      iterations: looping ? -1 : 1,
      playMode: looping ? PlayMode.Alternate : PlayMode.Normal
    }, (): void => {
      this.angle = looping ? (this.seed % 2 === 0 ? 0.7 : -0.7) : 0;
      this.lift = looping ? 0.7 : 0;
    });
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .rotate({ angle: this.angle })
    .translate({ y: this.lift })
    .onAppear((): void => { this.appeared = true; this.syncAnimation(); })
    .onDisAppear((): void => {
      this.appeared = false;
      this.looping = false;
      this.angle = 0;
      this.lift = 0;
    })
  }
}
