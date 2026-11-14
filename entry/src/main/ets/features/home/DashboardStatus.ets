import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { dashboardCardShadow, DASHBOARD_CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { DASHBOARD_COOKIE9, DASHBOARD_COOKIE12 } from './DashboardShapePaths';
import {
  homeHasPendingCleanup, homeRunActionLabel, homeRuntimeAppearsStarted, homeShouldStopRuntime
} from './HomeRunControls';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardCountryBadge } from './DashboardCountryBadge';

interface DashboardExitDetailField {
  label: ResourceStr;
  content: ResourceStr;
}

function dashboardUptime(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const hours = Math.floor(seconds / 3600);
  if (hours > 999) { return '999:59:59'; }
  const pad = (number: number): string => number.toString().padStart(2, '0');
  return `${pad(hours)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`;
}

@ComponentV2
export struct DashboardStatus {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileReady: boolean = false;
  @Param profileId: string = '';
  @Param routeRevision: string = '';
  @Local conn: Connection = connection;
  @Local settings: DashboardSettings = dashboardSettings;
  @Local probe: ExitIpProbe = exitIpProbe;
  @Local clock: number = Date.now();
  @Local details: boolean = false;
  private timer: number = -1;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.probe.cancel();
    this.stopTimer();
  }

  @Monitor('visible', 'profileId', 'routeRevision', 'conn.routeRevision', 'conn.forward', 'conn.mode', 'conn.sessionMode',
    'conn.state')
  sync(): void {
    const route = `${this.profileId}:${this.routeRevision}:${this.conn.routeRevision}:${this.conn.mode}:` +
      `${this.conn.sessionMode}:${this.conn.forward}`;
    this.probe.observe(this.context.filesDir, route, this.conn.connected, this.visible && !this.conn.busy);
    if (this.visible && this.timer === -1) {
      this.clock = Date.now();
      this.timer = setInterval((): void => { this.clock = Date.now(); }, 1000);
    } else if (!this.visible) {
      this.details = false;
      this.stopTimer();
    }
  }

  private stopTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private statusText(): ResourceStr {
    if (this.conn.hostState === 'unknown' && !this.conn.busy) {
      return $r('app.string.dash_runtime_unknown');
    }
    if (homeHasPendingCleanup(this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached) &&
      this.conn.state !== ConnectionState.Disconnecting) {
      return $r('app.string.dash_cleanup_required');
    }
    if (this.conn.forward === 'paused') {
      return $r('app.string.dash_paused');
    }
    if (this.conn.connected) {
      return this.conn.sessionMode === 'tun' ? $r('app.string.dash_tun_running') : $r('app.string.dash_proxy_running');
    }
    if (this.conn.state === ConnectionState.Disconnecting) {
      return $r('app.string.status_disconnecting');
    }
    if (this.conn.forward === 'preparing' || this.conn.state === ConnectionState.Connecting) {
      return $r('app.string.status_connecting');
    }
    return this.conn.forward === 'failed' ? $r('app.string.dash_start_failed') : $r('app.string.status_disconnected');
  }

  private address(): ResourceStr {
    if (this.settings.hideIp) {
      return '*****';
    }
    if (this.probe.result !== undefined) {
      return this.probe.result.ip;
    }
    return this.probe.busy ? $r('app.string.exit_ip_loading') : $r('app.string.dash_exit_failed');
  }

  private country(): string {
    const result = this.probe.result;
    if (result === undefined) {
      return '—';
    }
    try {
      return result.countryCode !== '' ? i18n.System.getDisplayCountry(result.countryCode,
        i18n.System.getSystemLocaleInstance().toString(), true) : result.country;
    } catch (e) {
      return result.country || '—';
    }
  }

  private shouldStop(): boolean {
    return homeShouldStopRuntime(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached,
      this.conn.hostState);
  }

  private appearsStarted(): boolean {
    return homeRuntimeAppearsStarted(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached);
  }

  private showRuntimeError(message: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 4000 });
  }

  private async toggleRun(): Promise<void> {
    if (!this.interactive) {
      return;
    }
    try {
      if (this.shouldStop()) {
        await this.conn.disconnect(this.context);
      } else if (this.profileReady) {
        await this.conn.connect(this.context);
      }
    } catch (e) {
      this.showRuntimeError(this.conn.error || (e as Error).message || $r('app.string.dash_runtime_error'));
    }
  }

  private async toggleHide(hidden: boolean): Promise<void> {
    try {
      await this.settings.commit({ hideIp: hidden }, this.settings.revision);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_save_failed') });
    }
  }

  private async copyExit(): Promise<void> {
    const result = this.probe.result;
    if (this.settings.hideIp || result === undefined) {
      return;
    }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, result.ip));
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copied') });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_copy_failed') });
    }
  }

  @Builder
  DetailField(field: DashboardExitDetailField) {
    Row({ space: 16 }) {
      Text(field.label)
        .fontSize(13)
        .lineHeight(18)
        .fontColor($r('sys.color.font_secondary'))
        .constraintSize({ maxWidth: '38%' })
      Text(field.content)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.End)
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  Details() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Text($r('app.string.dash_quality_unassessed'))
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 5, right: 5, top: 8 })
          Column({ space: 16 }) {
            Column({ space: 6 }) {
              Text($r('app.string.exit_ip'))
                .fontSize(13)
                .lineHeight(18)
                .fontColor($r('sys.color.font_secondary'))
              Text(this.address())
                .fontSize(22)
                .lineHeight(28)
                .fontWeight(600)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
                .copyOption(this.settings.hideIp ? CopyOptions.None : CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            this.DetailField({ label: $r('app.string.region_label'), content: this.country() })
            this.DetailField({ label: $r('app.string.dash_ip_organization'), content: this.probe.result?.org || '—' })
            this.DetailField({ label: $r('app.string.dash_ip_asn'), content: this.probe.result?.asn || '—' })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .borderRadius(22)
          .backgroundColor($r('app.color.tile_background'))
          Column({ space: 16 }) {
            this.DetailField({ label: $r('app.string.dash_probe_source'), content: this.probe.result?.source || '—' })
            this.DetailField({ label: $r('app.string.dash_probe_checked_at'), content: this.probe.result !== undefined ?
              new Date(this.probe.result.checkedAt).toLocaleString() : '—' })
            Row({ space: 16 }) {
              Text($r('app.string.dash_hide_ip'))
                .fontSize(15)
                .lineHeight(20)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.hideIp })
                .enabled(!this.settings.saving)
                .onChange((hidden: boolean): void => { this.toggleHide(hidden); })
            }
            .width('100%')
            .constraintSize({ minHeight: 40 })
          }
          .width('100%')
          .padding(16)
          .borderRadius(22)
          .backgroundColor($r('app.color.tile_background'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      Button($r('app.string.dash_copy_ip'))
        .width('100%')
        .height(40)
        .enabled(!this.settings.hideIp && this.probe.result !== undefined)
        .onClick((): void => { this.copyExit(); })
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 24, left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  Decoration() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Shape() {
        Path().commands(DASHBOARD_COOKIE12)
          .fill(this.conn.connected ? $r('app.color.dash_status_decoration') : $r('app.color.tile_background'))
          .strokeWidth(0)
      }
      .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
      .width(240)
      .height(240)
      .rotate({ angle: this.conn.connected ? 30 : 0 })
      .scale({ x: this.conn.connected ? 1.12 : 1, y: this.conn.connected ? 1.12 : 1 })
      .offset({ x: 60, y: -66 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 10 }) {
          Column() {
            Row({ space: 8 }) {
              AppGlyph({ name: 'status', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
              Text($r('app.string.card_status'))
                .fontSize(15)
                .lineHeight(20)
                .fontWeight(600)
              Row({ space: 4 }) {
                if (this.conn.connected) {
                  Circle({ width: 5, height: 5 }).fill($r('app.color.status_connected')).strokeWidth(0)
                }
                Text(this.conn.connected ? $r('app.string.chip_running') : this.statusText())
                  .fontSize(11)
                  .lineHeight(13)
                  .fontWeight(600)
                  .fontColor(this.conn.connected ? $r('app.color.status_connected') : $r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(7)
              .backgroundColor(this.conn.connected ? $r('app.color.dash_running_background') :
                $r('app.color.tile_background'))
            }
            .width('100%')
            .constraintSize({ minHeight: 26 })
            Row({ space: 12 }) {
              DashboardCountryBadge({ countryCode: this.probe.result?.countryCode ?? '', busy: this.probe.busy,
                running: this.conn.connected, visible: this.visible, interactive: this.interactive,
                onRefresh: (): void => { this.probe.refresh(); } })
              Column({ space: 4 }) {
                if (this.probe.result === undefined && !this.probe.failed && !this.settings.hideIp) {
                  Row()
                    .width('100%')
                    .height(22)
                    .borderRadius(4)
                    .backgroundColor($r('app.color.track'))
                    .opacity(0.55)
                    .margin({ top: 3, bottom: 3 })
                } else {
                  Text(this.address())
                    .fontSize(22)
                    .minFontSize(16.5)
                    .maxFontSize(22)
                    .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
                    .width('100%')
                    .lineHeight(28)
                    .fontWeight(FontWeight.Bold)
                    .fontFeature('"tnum" on')
                    .fontColor(this.probe.failed && this.probe.result === undefined ? $r('app.color.status_error') :
                      this.conn.connected ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                Text(this.probe.failed && this.probe.result === undefined ? $r('app.string.dash_retry_exit') :
                  $r('app.string.dash_quality_unassessed'))
                  .fontSize(12)
                  .lineHeight(16)
                  .height(28)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .onClick((): void => { if (this.interactive) { this.details = true; } })
            }
            .width('100%')
            .margin({ top: 12 })
            Row({ space: 24 }) {
              Column({ space: 2 }) {
                Text($r('app.string.uptime_label'))
                  .fontSize(12)
                  .lineHeight(16)
                  .fontColor($r('sys.color.font_secondary'))
                Text(this.conn.connected && this.conn.connectedAt > 0 ?
                  dashboardUptime(this.clock - this.conn.connectedAt) : '—')
                  .fontSize(15)
                  .lineHeight(20)
                  .fontWeight(600)
                  .fontFeature('"tnum" on')
              }
              .alignItems(HorizontalAlign.Start)
              Column({ space: 2 }) {
                Text($r('app.string.dash_ip_organization'))
                  .fontSize(12)
                  .lineHeight(16)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.probe.result?.org || this.probe.result?.asn || '—')
                  .fontSize(15)
                  .lineHeight(20)
                  .fontWeight(600)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 16 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button({ type: ButtonType.Normal }) {
            Stack() {
              if (this.appearsStarted()) {
                Shape() {
                  Path().commands(DASHBOARD_COOKIE9).fill($r('app.color.brand')).strokeWidth(0)
                }
                .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
                .width(88)
                .height(88)
                .rotate({ angle: 40 })
              } else {
                Circle({ width: 88, height: 88 })
                  .fill(this.profileReady ? $r('app.color.brand') : $r('app.color.tile_background'))
                  .strokeWidth(0)
              }
              if (this.conn.busy) {
                LoadingProgress().width(30).height(30).color(Color.White)
              } else {
                AppGlyph({ name: this.appearsStarted() ? 'pause' : 'play', iconSize: 30,
                  iconColor: this.profileReady || this.appearsStarted() ? Color.White : $r('sys.color.font_secondary') })
              }
            }
            .width(88)
            .height(88)
          }
          .width(88)
          .height(88)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .enabled(this.interactive && (this.profileReady || this.shouldStop()) &&
            this.conn.state !== ConnectionState.Disconnecting)
          .accessibilityText(homeRunActionLabel(this.conn.intent, this.conn.forward,
            this.conn.listenersOpen, this.conn.tunAttached, this.conn.hostState))
          .onClick((): void => { this.toggleRun(); })
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 18, bottom: 18 })
      }
      .width('100%')
      .background((): void => { this.Decoration(); })
      if (this.probe.stale || this.probe.failed || this.conn.error !== '') {
        Text(this.conn.error !== '' ? $r('app.string.dash_runtime_error') :
          this.probe.failure === 'capacity' ? $r('app.string.dash_probe_busy') :
          this.probe.failure === 'routeChanged' ? $r('app.string.dash_probe_changed') : $r('app.string.dash_stale_retry'))
          .fontSize(12)
          .fontColor(this.conn.error !== '' ? $r('app.color.status_error') : $r('app.color.warning'))
          .padding({ left: 20, right: 20, bottom: 12 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .background(dashboardCardShadow)
    .padding(0)
    .clip(true)
    .bindSheet($$this.details, (): void => { this.Details(); }, {
      title: { title: $r('app.string.dash_exit_details') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: true
    })
  }
}
