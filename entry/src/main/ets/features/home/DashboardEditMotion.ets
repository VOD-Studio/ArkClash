@ComponentV2
export struct DashboardEditMotion {
  @Param active: boolean = false;
  @Param seed: number = 0;
  @Param reduceMotion: boolean = true;
  @BuilderParam @Require content: () => void;
  @Local looping: boolean = false;
  private appeared: boolean = false;

  @Monitor('active', 'reduceMotion')
  syncAnimation(): void {
    // 监听阶段只同步目标；属性动画在原生节点更新时捕获变化，避免 V2 异步标脏落在显式动画闭包之外。
    this.looping = this.appeared && this.active && !this.reduceMotion;
  }

  build() {
    Column() {
      this.content()
    }
    .rotate({ angle: this.looping ? (this.seed % 2 === 0 ? 0.7 : -0.7) : 0 })
    .translate({ y: this.looping ? 0.7 : 0 })
    .animation({
      duration: this.looping ? 360 + this.seed % 3 * 60 : 0,
      curve: Curve.EaseInOut,
      iterations: this.looping ? -1 : 1,
      playMode: this.looping ? PlayMode.Alternate : PlayMode.Normal
    })
    .width('100%')
    .onAppear((): void => {
      // 首次节点先以零变换出现，再切换播放目标，确保编辑态新加入的卡片也有动画起点。
      this.appeared = true;
      this.syncAnimation();
    })
    .onDisAppear((): void => {
      this.appeared = false;
      this.syncAnimation();
    })
  }
}
