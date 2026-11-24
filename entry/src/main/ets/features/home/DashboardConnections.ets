import { common } from '@kit.AbilityKit';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { connection, Connection } from '../../client/Connection';
import { DiagnosticFeedTarget, DiagnosticStats } from '../../client/Diagnostics';
import { uiResourceText } from '../../components/ResourceText';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { dashboardCount } from './DashboardFormat';

@ComponentV2
export struct DashboardConnections {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Event onOpen: (target: DiagnosticFeedTarget) => void = (_target: DiagnosticFeedTarget): void => {};
  @Local private conn: Connection = connection;
  @Local private stats: DiagnosticStats = new DiagnosticStats();
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.stats.stop();
  }

  @Monitor('visible', 'conn.coreReady', 'conn.hostState', 'conn.bootId', 'conn.configRevision')
  sync(): void {
    const ready = this.conn.coreReady && this.conn.hostState === 'running';
    this.stats.observe(this.context.filesDir, this.visible, ready, this.conn.bootId, this.conn.configRevision);
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_conn_stats'), glyph: 'connections' })
      Row({ space: 8 }) {
        ConnectionStatTile({
          label: $r('app.string.dash_conn_live'),
          count: this.stats.live,
          interactive: this.interactive,
          onPress: (): void => { this.onOpen('live'); }
        })
          .layoutWeight(1)
        ConnectionStatTile({
          label: $r('app.string.dash_conn_recent'),
          count: this.stats.recent,
          interactive: this.interactive,
          onPress: (): void => { this.onOpen('recent'); }
        })
          .layoutWeight(1)
        ConnectionStatTile({
          label: $r('app.string.dash_conn_dns'),
          count: this.stats.dns,
          interactive: this.interactive,
          onPress: (): void => { this.onOpen('dns'); }
        })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .accessibilityText($r('app.string.card_conn_stats'))
  }
}

@ComponentV2
struct ConnectionStatTile {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: ResourceStr;
  @Param count: number = 0;
  @Param interactive: boolean = true;
  @Event onPress: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 4 }) {
        Text(dashboardCount(this.count))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(22)
          .minFontSize(16)
          .maxFontSize(22)
          .lineHeight(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .fontFeature('"tnum" on')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .lineHeight(16)
          .fontWeight(500)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .constraintSize({ minHeight: 74 })
    .padding({ left: 8, right: 8, top: 14, bottom: 14 })
    .borderRadius(20)
    .backgroundColor(this.appStyle.palette.tileBackground)
    .enabled(this.interactive)
    .accessibilityText(`${uiResourceText(this.getUIContext(), this.label)} ${dashboardCount(this.count)}`)
    .onClick((): void => { if (this.interactive) { this.onPress(); } })
  }
}
