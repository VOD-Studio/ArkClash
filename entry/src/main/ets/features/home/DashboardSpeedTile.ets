import { TrafficSample } from '../../client/Traffic';
import { dashboardTraffic, dashboardTrafficValue, DashboardTrafficValue } from './DashboardFormat';
import { dashboardTrafficGraph } from './TrafficChart';
import { AppGlyph } from '../../components/AppGlyph';

@ComponentV2
export struct DashboardSpeedTile {
  @Param upload: boolean = false;
  @Param rate: number = 0;
  @Param total: number = 0;
  @Param stale: boolean = false;
  @Param samples: TrafficSample[] = [];
  @Local tileWidth: number = 0;
  @Local tileHeight: number = 0;
  @Local linePath: string = '';
  @Local areaPath: string = '';

  @Computed
  get rateValue(): DashboardTrafficValue {
    return dashboardTrafficValue(this.rate);
  }

  @Monitor('samples', 'tileWidth', 'tileHeight')
  redraw(): void {
    const density = this.getUIContext().vp2px(1);
    const graph = dashboardTrafficGraph(this.samples, this.upload, (this.tileWidth + 4) * density,
      Math.max(0, this.tileHeight - 34) * density);
    this.linePath = graph.line;
    this.areaPath = graph.area;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Path({ width: this.tileWidth + 4, height: Math.max(0, this.tileHeight - 34) }).commands(this.areaPath)
          .fill(this.upload ? $r('app.color.dash_series_secondary') : $r('app.color.brand'))
          .fillOpacity(0.14)
          .strokeWidth(0)
        Path({ width: this.tileWidth + 4, height: Math.max(0, this.tileHeight - 34) }).commands(this.linePath)
          .fillOpacity(0)
          .stroke(this.upload ? $r('app.color.dash_series_secondary') : $r('app.color.brand'))
          .strokeWidth(1.5)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(this.tileWidth + 4)
      .height(Math.max(0, this.tileHeight - 34))
      .position({ x: -2, y: 36 })
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
      Column() {
        Row({ space: 4 }) {
          AppGlyph({ name: this.upload ? 'arrowUp' : 'arrowDown', iconSize: 16,
            iconColor: this.upload ? $r('sys.color.font_secondary') : $r('app.color.brand') })
          Text(this.upload ? $r('app.string.traffic_upload') : $r('app.string.traffic_download'))
            .fontSize(13)
            .lineHeight(18)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text() {
          Span(this.stale ? '—' : this.rateValue.amount)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(-0.56)
          Span(` ${this.rateValue.unit}/s`)
            .fontSize(13)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
        }
        .fontFeature('"tnum" on')
        .lineHeight(34)
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Clip })
        Text($r('app.string.traffic_total', dashboardTraffic(this.total)))
          .fontSize(12)
          .lineHeight(16)
          .fontColor($r('sys.color.font_secondary'))
          .fontFeature('"tnum" on')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, top: 14, right: 16, bottom: 12 })
    }
    .width('100%')
    .constraintSize({ minHeight: this.tileWidth / 1.45 })
    .borderRadius(22)
    .backgroundColor($r('app.color.tile_background'))
    .clip(true)
    .onAreaChange((_previous: Area, current: Area): void => {
      this.tileWidth = Number(current.width);
      this.tileHeight = Number(current.height);
    })
  }
}
