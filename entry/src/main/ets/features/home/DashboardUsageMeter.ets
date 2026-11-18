import { AppearanceState, appAppearance } from '../../components/AppearanceState';
@ComponentV2
export struct DashboardUsageMeter {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param share: number = 0;
  @Local meterWidth: number = 0;
  @Local wavePath: string = '';

  @Monitor('share', 'meterWidth')
  redraw(): void {
    const start = 2;
    const split = start + Math.max(0, this.meterWidth - 4) * this.share;
    // Path 的命令坐标用 px；布局、轨道和线宽用 vp，不能靠零尺寸子路径的 Shape 视口缩放。
    const density = this.getUIContext().vp2px(1);
    let path = `M${start * density} ${6 * density} `;
    for (let x = start; x <= split; x++) {
      path += `L${(x * density).toFixed(3)} ${((6 + 3 * Math.sin((x - start) / 12 * 2 * Math.PI)) * density).toFixed(3)} `;
    }
    this.wavePath = this.share > 0 ? path : '';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Path({ width: '100%', height: 12 })
        .commands(this.wavePath)
        .fillOpacity(0)
        .stroke(this.share >= 0.9 ? $r('app.color.warning') : this.appStyle.palette.brand)
        .strokeWidth(4)
        .strokeLineCap(LineCapStyle.Round)
      if ((this.share > 0 ? 2 + Math.max(0, this.meterWidth - 4) * this.share + 10 : 2) < this.meterWidth - 6) {
        Line()
          .startPoint([this.share > 0 ? 2 + Math.max(0, this.meterWidth - 4) * this.share + 10 : 2, 6])
          .endPoint([Math.max(2, this.meterWidth - 12), 6])
          .stroke(this.appStyle.palette.track)
          .strokeWidth(4)
          .strokeLineCap(LineCapStyle.Round)
      }
      if (this.share < 1) {
        Circle({ width: 4, height: 4 })
          .fill(this.share >= 0.9 ? $r('app.color.warning') : this.appStyle.palette.brand)
          .strokeWidth(0)
          .position({ x: Math.max(0, this.meterWidth - 6), y: 4 })
      }
    }
    .width('100%')
    .height(12)
    .onAreaChange((_previous: Area, current: Area): void => { this.meterWidth = Number(current.width); })
  }
}
