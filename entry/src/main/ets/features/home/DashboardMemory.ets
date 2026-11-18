import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { memoryStats, MemoryStats, UiMemoryStats } from '../../client/Stats';
import { dashboardTraffic, dashboardTrafficValue, DashboardTrafficValue } from './DashboardFormat';
import { LabeledValue } from '../../components/Labels';
import { DASHBOARD_CARD, PAGE_GUTTER } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardMemory {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;
  @Local core: MemoryStats = memoryStats;
  @Local ui: UiMemoryStats = new UiMemoryStats();
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

  @Monitor('visible', 'conn.state', 'conn.coreReady')
  sync(): void {
    if (!this.visible) {
      this.details = false;
      this.stop();
      return;
    }
    this.clock = Date.now();
    if (this.conn.coreReady) {
      this.core.start(this.context.filesDir, 'dashboard-memory');
    } else {
      this.core.stop('dashboard-memory');
    }
    if (this.timer === -1) {
      this.ui.refresh();
      this.timer = setInterval((): void => {
        this.clock = Date.now();
        this.ui.refresh();
      }, 5000);
    }
  }

  private stop(): void {
    this.core.stop('dashboard-memory');
    this.ui.stop();
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private stale(): boolean {
    return this.ui.failed || this.core.failed || (this.ui.sampledAt > 0 && this.clock - this.ui.sampledAt > 10000) ||
      (this.conn.coreReady && this.core.sampledAt > 0 && this.clock - this.core.sampledAt > 5000);
  }


  private totalRss(): number {
    return this.ui.rssBytes + (this.conn.coreReady && this.core.received ? this.core.coreBytes : 0);
  }

  private rssReady(): boolean {
    return this.ui.sampledAt > 0 && (this.conn.coreReady ? this.core.received :
      this.conn.hostState === 'stopped');
  }

  @Computed
  get totalRssValue(): DashboardTrafficValue {
    return dashboardTrafficValue(this.totalRss());
  }

  @Builder
  Details() {
    Scroll() {
      Column({ space: 16 }) {
        LabeledValue({ label: $r('app.string.dash_total_rss'),
          value: this.rssReady() ? dashboardTraffic(this.totalRss()) : '—' })
          .width('100%')
          .padding({ left: 5, right: 5, top: 8 })
        Column({ space: 12 }) {
          Text($r('app.string.dash_memory_app'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
          LabeledValue({ label: $r('app.string.dash_ui_rss'),
            value: this.ui.sampledAt > 0 ? dashboardTraffic(this.ui.rssBytes) : '—' })
            .width('100%')
          LabeledValue({ label: $r('app.string.dash_ui_pss_swap'),
            value: this.ui.sampledAt > 0 ? dashboardTraffic(this.ui.pssSwapBytes) : '—' })
            .width('100%')
          Text(this.ui.sampledAt > 0 ? new Date(this.ui.sampledAt).toLocaleString() : '—')
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(22)
        .backgroundColor(this.appStyle.palette.tileBackground)
        Column({ space: 12 }) {
          Text($r('app.string.dash_memory_core'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
          LabeledValue({ label: $r('app.string.dash_vpn_rss'),
            value: this.core.sampledAt > 0 ? dashboardTraffic(this.core.coreBytes) : '—' })
            .width('100%')
          Text(this.core.sampledAt > 0 ? new Date(this.core.sampledAt).toLocaleString() : '—')
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(22)
        .backgroundColor(this.appStyle.palette.tileBackground)
        if (this.stale()) {
          Text($r('app.string.dash_memory_stale'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('app.color.warning'))
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_memory'), glyph: 'memory', chevron: true })
      Column() {
        Text() {
          Span(this.rssReady() ? this.totalRssValue.amount : '—')
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(-0.56)
          Span(` ${this.totalRssValue.unit}`)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
        }
        .lineHeight(34)
        .fontFeature('"tnum" on')
        Text($r('app.string.dash_total_rss'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .lineHeight(16)
          .fontColor($r('sys.color.font_secondary'))
        Row({ space: 2 }) {
          if (this.rssReady() && this.totalRss() > 0) {
            Row().height(8).layoutWeight(Math.max(1, this.ui.rssBytes)).backgroundColor(this.appStyle.palette.brand)
            if (this.conn.coreReady && this.core.coreBytes > 0) {
              Row().height(8).layoutWeight(this.core.coreBytes).backgroundColor(this.appStyle.palette.dashSeriesSecondary)
            }
          }
        }
        .width('100%')
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.appStyle.palette.track)
        .clip(true)
        .margin({ top: 14 })
        Flex({ wrap: FlexWrap.Wrap }) {
          Row({ space: 6 }) {
            Circle({ width: 8, height: 8 }).fill(this.appStyle.palette.brand).strokeWidth(0)
            Text($r('app.string.dash_memory_app')).fontFamily(this.appStyle.fontFamily).fontSize(12).fontColor($r('sys.color.font_secondary'))
            Text(this.ui.sampledAt > 0 ? dashboardTraffic(this.ui.rssBytes) : '—')
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(13)
              .fontWeight(600)
              .fontFeature('"tnum" on')
          }
          .margin({ right: 16, bottom: 4 })
          Row({ space: 6 }) {
            Circle({ width: 8, height: 8 }).fill(this.appStyle.palette.dashSeriesSecondary).strokeWidth(0)
            Text($r('app.string.dash_memory_core')).fontFamily(this.appStyle.fontFamily).fontSize(12).fontColor($r('sys.color.font_secondary'))
            Text(this.conn.coreReady && this.core.received ? dashboardTraffic(this.core.coreBytes) : '—')
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(13)
              .fontWeight(600)
              .fontFeature('"tnum" on')
          }
          .margin({ right: 16, bottom: 4 })
        }
        .width('100%')
        .margin({ top: 10 })
        if (this.stale()) {
          Text($r('app.string.dash_memory_stale'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('app.color.warning'))
            .margin({ top: 8 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details, {
      title: { title: $r('app.string.card_memory') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: this.appStyle.sheetMaterial(), showClose: true
    })
  }
}
