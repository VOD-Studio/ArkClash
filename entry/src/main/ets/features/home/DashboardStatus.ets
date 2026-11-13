import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { exitIpProbe, ExitIpProbe, flagOf } from '../../client/ExitIp';
import { LabeledValue } from '../../components/Labels';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { homeHasPendingCleanup, homeRunActionLabel, homeShouldStopRuntime } from './HomeRunControls';

function dashboardUptime(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const pad = (number: number): string => number.toString().padStart(2, '0');
  return `${pad(Math.floor(seconds / 3600))}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`;
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
    return homeShouldStopRuntime(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached);
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
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_runtime_error') });
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
  Details() {
    Column({ space: 16 }) {
      Text(this.address())
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(this.country())
        .fontColor($r('sys.color.font_secondary'))
      Text(this.probe.result?.org || '—')
        .fontColor($r('sys.color.font_secondary'))
      Text(this.probe.result?.asn || '—')
        .fontColor($r('sys.color.font_secondary'))
      Text(this.probe.result?.source || '—')
        .fontColor($r('sys.color.font_tertiary'))
      Text(this.probe.result !== undefined ? new Date(this.probe.result.checkedAt).toLocaleString() : '—')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      Text($r('app.string.dash_quality_unassessed'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Row() {
        Text($r('app.string.dash_hide_ip'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.settings.hideIp })
          .enabled(!this.settings.saving)
          .onChange((hidden: boolean): void => { this.toggleHide(hidden); })
      }
      Button($r('app.string.dash_copy_ip'))
        .enabled(!this.settings.hideIp && this.probe.result !== undefined)
        .onClick((): void => { this.copyExit(); })
    }
    .width('100%')
    .padding(PAGE_GUTTER)
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.checkmark_shield'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
        Text($r('app.string.card_status'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Button(homeRunActionLabel(this.conn.intent, this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached))
          .height(36)
          .enabled(this.interactive && (this.profileReady || this.shouldStop()) &&
            this.conn.state !== ConnectionState.Disconnecting)
          .onClick((): void => { this.toggleRun(); })
      }
      .width('100%')
      Text(this.statusText())
        .fontColor(this.conn.connected ? $r('app.color.status_connected') : $r('sys.color.font_secondary'))
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.probe.busy) {
            LoadingProgress().width(24).height(24)
          } else {
            Text(flagOf(this.probe.result?.countryCode ?? '') || '↻').fontSize(24)
          }
        }
        .width(48)
        .height(48)
        .backgroundColor($r('app.color.tile_background'))
        .enabled(this.interactive && !this.probe.busy)
        .accessibilityText($r('app.string.dash_retry_exit'))
        .onClick((): void => { this.probe.refresh(); })
        Column({ space: 4 }) {
          Text(this.address())
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.conn.connected ? $r('app.string.dash_routed_exit') : $r('app.string.exit_local'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick((): void => { if (this.interactive) { this.details = true; } })
      }
      .width('100%')
      if (this.probe.stale || this.probe.failed) {
        Text(this.probe.failure === 'capacity' ? $r('app.string.dash_probe_busy') : this.probe.failure === 'routeChanged' ?
          $r('app.string.dash_probe_changed') : $r('app.string.dash_stale_retry'))
          .fontSize(12)
          .fontColor($r('app.color.warning'))
      }
      if (this.conn.error !== '') {
        Text($r('app.string.dash_runtime_error'))
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
      }
      Row() {
        LabeledValue({ label: $r('app.string.uptime_label'), value: this.conn.connected && this.conn.connectedAt > 0 ?
          dashboardUptime(this.clock - this.conn.connectedAt) : '—' }).layoutWeight(1)
        LabeledValue({ label: $r('app.string.region_label'), value: this.country() }).layoutWeight(1)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .bindSheet($$this.details, this.Details(), {
      title: { title: $r('app.string.dash_exit_details') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: true
    })
  }
}
