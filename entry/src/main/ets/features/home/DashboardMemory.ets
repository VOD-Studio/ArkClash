import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { memoryStats, MemoryStats, UiMemoryStats } from '../../client/Stats';
import { formatBytes } from '../../components/Format';
import { LabeledValue } from '../../components/Labels';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardMemory {
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

  @Monitor('visible', 'conn.state')
  sync(): void {
    if (!this.visible) {
      this.details = false;
      this.stop();
      return;
    }
    this.clock = Date.now();
    if (this.conn.connected) {
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
      (this.conn.connected && this.core.sampledAt > 0 && this.clock - this.core.sampledAt > 5000);
  }

  @Builder
  Details() {
    Column({ space: 16 }) {
      LabeledValue({ label: $r('app.string.dash_ui_pss_swap'),
        value: this.ui.sampledAt > 0 ? formatBytes(this.ui.pssSwapBytes) : '—' })
      LabeledValue({ label: $r('app.string.dash_ui_rss'),
        value: this.ui.sampledAt > 0 ? formatBytes(this.ui.rssBytes) : '—' })
      Text(this.ui.sampledAt > 0 ? new Date(this.ui.sampledAt).toLocaleString() : '—')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      LabeledValue({ label: $r('app.string.dash_vpn_rss'),
        value: this.core.sampledAt > 0 ? formatBytes(this.core.coreBytes) : '—' })
      Text(this.core.sampledAt > 0 ? new Date(this.core.sampledAt).toLocaleString() : '—')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      Text($r('app.string.dash_memory_scope'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .padding(PAGE_GUTTER)
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_memory'), symbol: $r('sys.symbol.rectangle_stack'), chevron: true })
      Row({ space: 12 }) {
        LabeledValue({ label: $r('app.string.dash_ui_pss_swap'),
          value: this.ui.sampledAt > 0 ? formatBytes(this.ui.pssSwapBytes) : '—' }).layoutWeight(1)
        LabeledValue({ label: $r('app.string.dash_vpn_rss'),
          value: this.conn.connected && this.core.received ? formatBytes(this.core.coreBytes) : '—' }).layoutWeight(1)
      }
      .width('100%')
      Text(this.stale() ? $r('app.string.dash_memory_stale') : $r('app.string.dash_memory_scope_short'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details(), {
      title: { title: $r('app.string.card_memory') }, detents: [SheetSize.MEDIUM],
      systemMaterial: sheetMaterial(), showClose: true
    })
  }
}
