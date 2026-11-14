import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { traffic, Traffic } from '../../client/Traffic';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { DashboardSpeedTile } from './DashboardSpeedTile';


@ComponentV2
export struct DashboardSpeed {
  @Param visible: boolean = false;
  @Local conn: Connection = connection;
  @Local stats: Traffic = traffic;
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

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_speed'), glyph: 'speed' })
      Row({ space: 10 }) {
        DashboardSpeedTile({ upload: true, rate: this.conn.connected ? this.stats.up : 0,
          total: this.stats.upTotal, stale: this.stats.stale && this.conn.connected, samples: this.stats.samples })
          .layoutWeight(1)
        DashboardSpeedTile({ upload: false, rate: this.conn.connected ? this.stats.down : 0,
          total: this.stats.downTotal, stale: this.stats.stale && this.conn.connected, samples: this.stats.samples })
          .layoutWeight(1)
      }
      .width('100%')
      if (this.stats.stale && this.conn.connected) {
        Text($r('app.string.dash_traffic_stale'))
          .fontSize(12)
          .fontColor($r('app.color.warning'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
  }
}
