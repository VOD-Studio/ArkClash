@ComponentV2
export struct DashboardUsageMeter {
  @Param share: number = 0;
  @Local meterWidth: number = 0;
  @Local wavePath: string = '';

  @Monitor('share', 'meterWidth')
  redraw(): void {
    const start = 2;
    const split = start + Math.max(0, this.meterWidth - 4) * this.share;
    let path = `M${start} 6 `;
    for (let x = start; x <= split; x++) {
      path += `L${x} ${(6 + 3 * Math.sin((x - start) / 12 * 2 * Math.PI)).toFixed(3)} `;
    }
    this.wavePath = this.share > 0 ? path : '';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Shape() {
        Path().commands(this.wavePath)
          .fillOpacity(0)
          .stroke(this.share >= 0.9 ? $r('app.color.warning') : $r('app.color.brand'))
          .strokeWidth('4px')
          .strokeLineCap(LineCapStyle.Round)
      }
      .viewPort({ x: '0px', y: '0px', width: `${Math.max(1, this.meterWidth)}px`, height: '12px' })
      .width('100%')
      .height(12)
      if ((this.share > 0 ? 2 + Math.max(0, this.meterWidth - 4) * this.share + 10 : 2) < this.meterWidth - 6) {
        Line()
          .startPoint([this.share > 0 ? 2 + Math.max(0, this.meterWidth - 4) * this.share + 10 : 2, 6])
          .endPoint([Math.max(2, this.meterWidth - 12), 6])
          .stroke($r('app.color.track'))
          .strokeWidth(4)
          .strokeLineCap(LineCapStyle.Round)
      }
      if (this.share < 1) {
        Circle({ width: 4, height: 4 })
          .fill(this.share >= 0.9 ? $r('app.color.warning') : $r('app.color.brand'))
          .strokeWidth(0)
          .position({ x: Math.max(0, this.meterWidth - 6), y: 4 })
      }
    }
    .width('100%')
    .height(12)
    .onAreaChange((_previous: Area, current: Area): void => { this.meterWidth = Number(current.width); })
  }
}
