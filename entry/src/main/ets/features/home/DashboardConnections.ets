import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { connectionStats, ConnectionStats } from '../../client/Stats';
import { dashboardCardShadow, DASHBOARD_CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { DashboardFigure } from './DashboardFigure';
import { dashboardCount } from './DashboardFormat';

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
    return this.conn.connected && this.stats.received ? dashboardCount(number) : '—';
  }

  private stale(): boolean {
    return this.stats.failed || (this.stats.sampledAt > 0 && this.clock - this.stats.sampledAt > 3500);
  }


  @Builder
  Counts() {
    Row() {
      DashboardFigure({ figureText: this.count(this.stats.active), label: $r('app.string.stat_active'),
        figureSize: 22, figureLeading: 28, figureWeight: 700, centered: true })
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10 })
      DashboardFigure({ figureText: this.count(this.stats.proxied), label: $r('app.string.stat_proxied'),
        figureSize: 22, figureLeading: 28, figureWeight: 700, centered: true })
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10 })
      DashboardFigure({ figureText: this.count(this.stats.direct), label: $r('app.string.stat_direct'),
        figureSize: 22, figureLeading: 28, figureWeight: 700, centered: true })
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10 })
    }
    .width('100%')
  }

  @Builder
  Details() {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          this.Counts()
        }
        .width('100%')
        .padding(8)
        .borderRadius(22)
        .backgroundColor($r('app.color.tile_background'))
        Text($r('app.string.dash_connections_scope'))
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Text(this.stats.sampledAt > 0 ? new Date(this.stats.sampledAt).toLocaleString() : '—')
          .fontSize(12)
          .lineHeight(16)
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
        if (this.stale()) {
          Text($r('app.string.dash_stats_stale'))
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('app.color.warning'))
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      this.Counts()
      if (this.stale()) {
        Text($r('app.string.dash_stats_stale'))
          .fontSize(12)
          .fontColor($r('app.color.warning'))
      }
    }
    .attributeModifier(DASHBOARD_CARD)
    .background(dashboardCardShadow)
    .padding(8)
    .accessibilityText($r('app.string.card_conn_stats'))
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details, {
      title: { title: $r('app.string.card_conn_stats') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: true
    })
  }
}
