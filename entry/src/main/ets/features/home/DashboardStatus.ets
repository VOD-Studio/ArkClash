import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { DASHBOARD_CARD } from '../../components/Theme';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { DASHBOARD_COOKIE12 } from './DashboardShapePaths';
import {
  homeHasPendingCleanup, homeRunActionLabel, homeRunFailureMessage, homeRuntimeAppearsStarted, homeShouldStopRuntime
} from './HomeRunControls';
import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardCountryBadge } from './DashboardCountryBadge';
import { DashboardExitDetails } from './DashboardExitDetails';
import { DashboardIpQuality } from './DashboardIpQuality';
import { DashboardRunButton } from './DashboardRunButton';
import { DashboardLoadingRotation } from './DashboardLoadingRotation';

const START_CURVE = curves.cubicBezierCurve(0.175, 0.885, 0.32, 1.275);
const STOP_CURVE = curves.cubicBezierCurve(0.55, 0.055, 0.675, 0.19);

function dashboardUptime(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const hours = Math.floor(seconds / 3600);
  if (hours > 999) { return '999:59:59'; }
  const pad = (number: number): string => number.toString().padStart(2, '0');
  return `${pad(hours)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`;
}

@ComponentV2
export struct DashboardStatus {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param motionEnabled: boolean = false;
  @Param profileReady: boolean = false;
  @Param profileId: string = '';
  @Param routeRevision: string = '';
  @Local conn: Connection = connection;
  @Local settings: DashboardSettings = dashboardSettings;
  @Local probe: ExitIpProbe = exitIpProbe;
  @Local clock: number = Date.now();
  @Local details: boolean = false;
  private timer: number = -1;
  private appeared: boolean = false;
  private refreshGeneration: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.appeared = true;
    this.sync();
  }

  aboutToDisappear(): void {
    this.appeared = false;
    this.refreshGeneration++;
    this.probe.cancel();
    this.stopTimer();
  }

  @Monitor('visible', 'profileId', 'routeRevision', 'conn.routeRevision', 'conn.forward', 'conn.mode', 'conn.sessionMode',
    'conn.state')
  sync(): void {
    this.refreshGeneration++;
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
    if (this.cleanupPending() && this.conn.state !== ConnectionState.Disconnecting) {
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

  private shouldStop(): boolean {
    return homeShouldStopRuntime(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached,
      this.conn.vpnCreated, this.conn.hostState);
  }

  private cleanupPending(): boolean {
    return homeHasPendingCleanup(this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached,
      this.conn.vpnCreated, this.conn.hostState);
  }

  private appearsStarted(): boolean {
    return this.conn.state !== ConnectionState.Disconnecting &&
      homeRuntimeAppearsStarted(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached,
        this.conn.vpnCreated, this.conn.hostState);
  }

  private showRuntimeError(message: ResourceStr): void {
    if (this.appeared && this.visible) {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 4000 });
    }
  }

  private async refreshExit(): Promise<void> {
    if (!this.appeared || !this.visible || !this.interactive || this.conn.busy || this.probe.busy) {
      return;
    }
    const generation = ++this.refreshGeneration;
    await this.probe.refresh();
    if (generation !== this.refreshGeneration) {
      return;
    }
    if (this.probe.failed) {
      this.showRuntimeError(this.probe.failure === 'capacity' ? $r('app.string.dash_probe_busy') :
        this.probe.failure === 'routeChanged' ? $r('app.string.dash_probe_changed') :
        $r('app.string.dash_exit_failed'));
    } else if (this.probe.qualityFailed) {
      this.showRuntimeError($r('app.string.dash_ip_quality_failed'));
    }
  }

  private async toggleRun(): Promise<void> {
    if (!this.interactive) {
      return;
    }
    const shouldStop = this.shouldStop();
    try {
      if (shouldStop) {
        await this.conn.disconnect(this.context);
      } else if (this.profileReady) {
        hilog.info(0x0A11, 'ArkClashBench', 'vpn_connect_click');
        await this.conn.connect(this.context);
      }
    } catch (e) {
      this.showRuntimeError(homeRunFailureMessage((e as Error).message, this.cleanupPending(),
        shouldStop ? $r('app.string.dash_vpn_stop_failed') : $r('app.string.dash_vpn_connect_failed')));
    }
  }

  private statusError(): Resource {
    return homeRunFailureMessage(this.conn.error, this.cleanupPending(), $r('app.string.dash_runtime_error'));
  }

  @Builder
  Details() {
    DashboardExitDetails({ visible: this.visible && this.details, onRefresh: (): void => { this.refreshExit(); } })
  }

  @Builder
  Decoration() {
    Stack() {
      DashboardLoadingRotation({ active: this.conn.busy, visible: this.visible, motionEnabled: this.motionEnabled,
        sideLength: 240, duration: 6000 }) {
        Shape() {
          Path().commands(DASHBOARD_COOKIE12)
            .fill(this.conn.connected ? this.appStyle.palette.dashStatusDecoration : this.appStyle.palette.dashStatusIdleDecoration)
            .strokeWidth(0)
            .animation({ duration: this.motionEnabled && this.visible ? 450 : 0, curve: Curve.EaseOut })
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(240)
        .height(240)
        .rotate({ angle: this.appearsStarted() ? 30 : 0 })
        .scale({ x: this.appearsStarted() ? 1.12 : 1, y: this.appearsStarted() ? 1.12 : 1 })
        .animation({ duration: this.motionEnabled ? 450 : 0, curve: this.appearsStarted() ? START_CURVE : STOP_CURVE })
      }
    }
    .width(240)
    .height(240)
    .position({ right: -60, top: -66 })
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }

  build() {
    Column() {
      Column() {
        this.Decoration()
        Row({ space: 10 }) {
          Column() {
            Row({ space: 8 }) {
              AppGlyph({ name: 'status', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
              Text($r('app.string.card_status'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(15)
                .lineHeight(20)
                .fontWeight(600)
              Row({ space: 4 }) {
                if (this.conn.connected) {
                  Circle({ width: 5, height: 5 }).fill($r('app.color.success_foreground')).strokeWidth(0)
                }
                Text(this.conn.connected ? $r('app.string.chip_running') : this.statusText())
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(11)
                  .lineHeight(13)
                  .fontWeight(600)
                  .fontColor(this.conn.connected ? $r('app.color.success_foreground') : $r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(7)
              .backgroundColor(this.conn.connected ? $r('app.color.success_soft') :
                this.appStyle.palette.tileBackground)
              .accessibilityDescription(this.conn.error === '' ? '' : uiResourceText(this.getUIContext(), this.statusError()))
              .onClick((): void => {
                if (this.interactive && this.conn.error !== '') { this.showRuntimeError(this.statusError()); }
              })
            }
            .width('100%')
            .constraintSize({ minHeight: 26 })
            Row({ space: 12 }) {
              DashboardCountryBadge({ countryCode: this.probe.result?.countryCode ?? '', busy: this.probe.busy,
                running: this.conn.connected, motionEnabled: this.motionEnabled, interactive: this.interactive,
                onRefresh: (): void => { this.refreshExit(); } })
              Column({ space: 4 }) {
                if (this.probe.result === undefined && !this.probe.failed && !this.settings.hideIp) {
                  Row()
                    .width('100%')
                    .height(22)
                    .borderRadius(4)
                    .backgroundColor(this.appStyle.palette.track)
                    .opacity(0.55)
                    .margin({ top: 3, bottom: 3 })
                } else {
                  Text(this.address())
                    .fontFamily(this.appStyle.fontFamily)
                    .fontSize(22)
                    .minFontSize(16.5)
                    .maxFontSize(22)
                    .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
                    .width('100%')
                    .lineHeight(28)
                    .height(28)
                    .fontWeight(FontWeight.Bold)
                    .fontFeature('"tnum" on')
                    .fontColor(this.probe.failed && this.probe.result === undefined ? $r('app.color.status_error') :
                      this.conn.connected ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                DashboardIpQuality({ quality: this.probe.quality,
                  busy: this.probe.quality === undefined && (this.probe.busy || this.probe.qualityBusy || this.conn.busy) })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .constraintSize({ minHeight: 56 })
              .onClick((): void => { if (this.interactive) { this.details = true; } })
            }
            .width('100%')
            .margin({ top: 12 })
            Row({ space: 24 }) {
              Column({ space: 2 }) {
                Text($r('app.string.uptime_label'))
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(12)
                  .lineHeight(16)
                  .fontColor($r('sys.color.font_secondary'))
                Text(this.conn.connected && this.conn.connectedAt > 0 ?
                  dashboardUptime(this.clock - this.conn.connectedAt) : '—')
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(15)
                  .lineHeight(20)
                  .fontWeight(600)
                  .fontFeature('"tnum" on')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Column({ space: 2 }) {
                Text($r('app.string.dash_ip_organization'))
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(12)
                  .lineHeight(16)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.probe.result?.org || this.probe.result?.asn || '—')
                  .fontFamily(this.appStyle.fontFamily)
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
          DashboardRunButton({
            running: this.appearsStarted(), busy: this.conn.busy, visible: this.visible,
            available: this.profileReady || this.shouldStop(),
            motionEnabled: this.motionEnabled,
            interactive: this.interactive && (this.profileReady || this.shouldStop()) &&
              this.conn.state !== ConnectionState.Disconnecting,
            label: homeRunActionLabel(this.conn.intent, this.conn.forward,
              this.conn.listenersOpen, this.conn.tunAttached, this.conn.vpnCreated, this.conn.hostState),
            onToggle: (): void => { this.toggleRun(); }
          })
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 18, bottom: 18 })
      }
      .width('100%')
      .borderRadius(34)
      .clip(true)
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .padding(0)
    .bindSheet($$this.details, this.Details, {
      title: { title: $r('app.string.dash_exit_details') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: this.appStyle.sheetMaterial(), showClose: true
    })
  }
}
