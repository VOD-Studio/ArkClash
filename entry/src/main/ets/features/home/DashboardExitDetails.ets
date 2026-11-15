import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { PAGE_GUTTER } from '../../components/Theme';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { exitIpQualityLabel, exitIpTypeLabel } from './DashboardIpQuality';

interface DashboardExitDetailField {
  label: ResourceStr;
  content: ResourceStr;
}

@ComponentV2
export struct DashboardExitDetails {
  @Local probe: ExitIpProbe = exitIpProbe;
  @Local settings: DashboardSettings = dashboardSettings;

  private address(): ResourceStr {
    return this.settings.hideIp ? '*****' : this.probe.result?.ip ??
      (this.probe.busy ? $r('app.string.exit_ip_loading') : $r('app.string.dash_exit_failed'));
  }

  private country(): string {
    const result = this.probe.result;
    if (result === undefined) { return '—'; }
    try {
      return result.countryCode !== '' ? i18n.System.getDisplayCountry(result.countryCode,
        i18n.System.getSystemLocaleInstance().toString(), true) : result.country;
    } catch (e) {
      return result.country || '—';
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
    if (this.settings.hideIp || result === undefined) { return; }
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

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          if (this.probe.stale || this.probe.failed) {
            Text(this.probe.failure === 'capacity' ? $r('app.string.dash_probe_busy') :
              this.probe.failure === 'routeChanged' ? $r('app.string.dash_probe_changed') : $r('app.string.dash_stale_retry'))
              .fontSize(13)
              .lineHeight(18)
              .fontColor($r('app.color.warning'))
              .width('100%')
              .padding({ left: 5, right: 5 })
          }
          if (this.probe.qualityFailed) {
            Text($r('app.string.dash_ip_quality_failed'))
              .fontSize(13)
              .fontColor($r('app.color.warning'))
              .onClick((): void => { this.probe.refresh(); })
          }
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
            this.DetailField({ label: $r('app.string.dash_ip_type'),
              content: exitIpTypeLabel(this.probe.quality, this.probe.qualityBusy) })
            this.DetailField({ label: $r('app.string.dash_ip_quality'),
              content: exitIpQualityLabel(this.probe.quality, this.probe.qualityBusy) })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .borderRadius(22)
          .backgroundColor($r('app.color.tile_background'))
          Column({ space: 16 }) {
            this.DetailField({ label: $r('app.string.dash_probe_source'), content: this.probe.result?.source || '—' })
            this.DetailField({ label: $r('app.string.dash_ip_quality_source'), content: this.probe.quality?.source || '—' })
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
}
