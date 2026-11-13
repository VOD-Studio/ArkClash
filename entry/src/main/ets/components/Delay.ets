@ComponentV2
export struct Delay {
  @Param delayValue: number = 0;
  @Param stage: 'idle' | 'queued' | 'running' = 'idle';
  @Param canTest: boolean = true;
  @Param active: boolean = true;
  @Event onTest: () => void = () => {};

  private delayColor(): ResourceColor {
    if (this.delayValue < 0) {
      return $r('app.color.status_error');
    }
    if (this.delayValue >= 600) {
      return $r('app.color.warning');
    }
    return this.delayValue > 0 ? $r('app.color.status_connected') : $r('sys.color.font_tertiary');
  }

  private delayLabel(): Resource {
    if (this.stage === 'queued') {
      return $r('app.string.proxy_test_queued');
    }
    if (this.stage === 'running') {
      return $r('app.string.proxy_test_running');
    }
    if (this.delayValue === -1) {
      return $r('app.string.proxy_test_timeout');
    }
    if (this.delayValue === -2) {
      return $r('app.string.proxy_test_failed');
    }
    return this.delayValue > 0 ? $r('app.string.proxy_delay_ms', this.delayValue) : $r('app.string.delay_untested');
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      if (this.stage === 'running' && this.active) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.brand'))
          .enableLoading(this.active)
      } else if (this.stage === 'queued') {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
      } else if (this.delayValue === 0) {
        SymbolGlyph($r('sys.symbol.bolt'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_tertiary')])
      } else {
        Text(this.delayLabel())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.delayColor())
          .textAlign(TextAlign.Center)
      }
    }
    .constraintSize({ minWidth: 60, minHeight: 48 })
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .backgroundColor(Color.Transparent)
    .enabled(this.canTest && this.stage === 'idle')
    .accessibilityText($r('app.string.proxy_test_node'))
    .accessibilityDescription(this.delayLabel())
    .onClick(() => this.onTest())
  }
}
