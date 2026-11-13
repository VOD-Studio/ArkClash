import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { connectionStats, ConnectionStats } from '../../client/Stats';
import { LabeledValue } from '../../components/Labels';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardConnections {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;
  @Local stats: ConnectionStats = connectionStats;
  @Local details: boolean = false;
  @Local clock: number = Date.now();
  private timer: number = -1;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.stop();
  }

  @Monitor('visible', 'conn.state')
  sync(): void {
    if (this.visible && this.conn.connected) {
      this.stats.start(this.context.filesDir, 'dashboard-connections');
      if (this.timer === -1) {
        this.timer = setInterval((): void => { this.clock = Date.now(); }, 1000);
      }
    } else {
      this.stop();
    }
    if (!this.visible) {
      this.details = false;
    }
    if (this.conn.forward === 'stopped' && this.conn.intent === 'stopped') {
      this.stats.reset();
    }
  }

  private stop(): void {
    this.stats.stop('dashboard-connections');
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private count(number: number): string {
    return this.conn.connected && this.stats.received ? number.toLocaleString() : '—';
  }

  private stale(): boolean {
    return this.stats.failed || (this.stats.sampledAt > 0 && this.clock - this.stats.sampledAt > 3500);
  }

  @Builder
  Counts() {
    Row({ space: 8 }) {
      LabeledValue({ label: $r('app.string.stat_active'), value: this.count(this.stats.active) }).layoutWeight(1)
      LabeledValue({ label: $r('app.string.stat_proxied'), value: this.count(this.stats.proxied) }).layoutWeight(1)
      LabeledValue({ label: $r('app.string.stat_direct'), value: this.count(this.stats.direct) }).layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  Details() {
    Column({ space: 16 }) {
      this.Counts()
      Text($r('app.string.dash_connections_scope'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(this.stats.sampledAt > 0 ? new Date(this.stats.sampledAt).toLocaleString() : '—')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      if (this.stale()) {
        Text($r('app.string.dash_stats_stale'))
          .fontSize(12)
          .fontColor($r('app.color.warning'))
      }
    }
    .width('100%')
    .padding(PAGE_GUTTER)
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_conn_stats'), symbol: $r('sys.symbol.list_bullet'), chevron: true })
      this.Counts()
      Text(this.stale() ? $r('app.string.dash_stats_stale') : $r('app.string.dash_connections_live'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details(), {
      title: { title: $r('app.string.card_conn_stats') }, detents: [SheetSize.MEDIUM],
      systemMaterial: sheetMaterial(), showClose: true
    })
  }
}
