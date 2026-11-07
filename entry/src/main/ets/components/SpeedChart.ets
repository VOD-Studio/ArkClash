// 低于这个速率时纵轴不再缩小，避免几百字节的抖动被放大成满幅波动。
const MIN_SCALE = 16 * 1024;

/** 上传、下载两条速率折线，共用一个纵轴，最新的样本在最右边。 */
@ComponentV2
export struct SpeedChart {
  @Param up: number[] = [];
  @Param down: number[] = [];
  @Param capacity: number = 60; // 横轴的样本数
  @Param chartHeight: number = 64;
  @Local chartWidth: number = 0;

  build() {
    Stack() {
      // 基线
      Divider()
        .color($r('app.color.divider'))
        .position({ x: 0, y: this.chartHeight - 1 })
      Polyline({ width: this.chartWidth, height: this.chartHeight })
        .points(this.points(this.up))
        .fillOpacity(0)
        .stroke($r('app.color.upload'))
        .strokeWidth(2)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeLineCap(LineCapStyle.Round)
      Polyline({ width: this.chartWidth, height: this.chartHeight })
        .points(this.points(this.down))
        .fillOpacity(0)
        .stroke($r('app.color.download'))
        .strokeWidth(2)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeLineCap(LineCapStyle.Round)
    }
    .width('100%')
    .height(this.chartHeight)
    .onAreaChange((_old: Area, area: Area) => {
      this.chartWidth = area.width as number;
    })
  }

  private points(samples: number[]): number[][] {
    if (this.chartWidth <= 0 || samples.length < 2) {
      return [];
    }
    let max = MIN_SCALE;
    for (const v of this.up) {
      max = Math.max(max, v);
    }
    for (const v of this.down) {
      max = Math.max(max, v);
    }
    const step = this.chartWidth / (this.capacity - 1);
    const offset = this.capacity - samples.length;
    // 上下各留 1vp，线宽不被裁掉。
    const usable = this.chartHeight - 2;
    return samples.map((v: number, i: number): number[] => [(offset + i) * step, 1 + usable * (1 - v / max)]);
  }
}
