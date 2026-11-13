import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { traffic, Traffic } from '../../client/Traffic';
import { formatBytes, splitBytes } from '../../components/Format';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { dashboardTrafficPath } from './TrafficChart';


@ComponentV2
export struct DashboardSpeed {
  @Param visible: boolean = false;
  @Local conn: Connection = connection;
  @Local stats: Traffic = traffic;
  @Local graphWidth: number = 0;
  @Local uploadPath: string = '';
  @Local downloadPath: string = '';
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.stats.stop('dashboard-speed');
  }

  @Monitor('visible', 'conn.state', 'conn.forward')
  sync(): void {
    if (this.visible && this.conn.connected) {
      this.stats.start(this.context.filesDir, 'dashboard-speed');
    } else {
      this.stats.stop('dashboard-speed');
    }
    if (this.conn.forward === 'stopped' && this.conn.intent === 'stopped') {
      this.stats.reset();
    }
  }

  @Monitor('stats.samples', 'graphWidth')
  redraw(): void {
    this.uploadPath = dashboardTrafficPath(this.stats.samples, true, this.graphWidth, 56);
    this.downloadPath = dashboardTrafficPath(this.stats.samples, false, this.graphWidth, 56);
  }

  private speed(upload: boolean): string {
    if (!this.conn.connected) {
      return '0';
    }
    return this.stats.stale ? '—' : splitBytes(upload ? this.stats.up : this.stats.down)[0];
  }

  private unit(upload: boolean): string {
    return `${splitBytes(this.conn.connected ? (upload ? this.stats.up : this.stats.down) : 0)[1]}/s`;
  }

  @Builder
  Rate(upload: boolean) {
    Column({ space: 4 }) {
      Text(upload ? $r('app.string.traffic_upload') : $r('app.string.traffic_download'))
        .fontSize(13)
        .fontColor(upload ? $r('app.color.upload') : $r('app.color.download'))
      Row({ space: 4 }) {
        Text(this.speed(upload))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontFeature('"tnum" on')
        Text(this.unit(upload))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      Text($r('app.string.traffic_total', formatBytes(upload ? this.stats.upTotal : this.stats.downTotal)))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.tile_background'))
  }

  build() {
    Column() {
      DashboardCardHeader({ title: $r('app.string.card_speed'), symbol: $r('sys.symbol.gauge_with_dots_needle_33percent') })
      Row({ space: 10 }) {
        this.Rate(true)
        this.Rate(false)
      }
      .width('100%')
      Stack() {
        Divider()
          .color($r('app.color.divider'))
          .position({ x: 0, y: 55 })
        Path({ width: this.graphWidth, height: 56 })
          .commands(this.uploadPath)
          .fillOpacity(0)
          .stroke($r('app.color.upload'))
          .strokeWidth(2)
        Path({ width: this.graphWidth, height: 56 })
          .commands(this.downloadPath)
          .fillOpacity(0)
          .stroke($r('app.color.download'))
          .strokeWidth(2)
      }
      .width('100%')
      .height(56)
      .margin({ top: 12 })
      .onAreaChange((_previous: Area, current: Area): void => { this.graphWidth = Number(current.width); })
      Text(this.stats.stale && this.conn.connected ? $r('app.string.dash_traffic_stale') :
        $r('app.string.dash_traffic_window'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .margin({ top: 8 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}
