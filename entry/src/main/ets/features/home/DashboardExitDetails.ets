import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { uiResourceText } from '../../components/ResourceText';
import { PAGE_GUTTER } from '../../components/Theme';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { exitIpQualityLabel, exitIpTypeLabel } from './DashboardIpQuality';

interface DashboardExitDetailField {
  label: ResourceStr;
  content: ResourceStr;
  loading?: boolean;
  retry?: boolean;
}

@ComponentV2
export struct DashboardExitDetails {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Event onRefresh: () => void = (): void => {};
  @Local probe: ExitIpProbe = exitIpProbe;
  @Local settings: DashboardSettings = dashboardSettings;
  @Local copying: boolean = false;
  private appeared: boolean = false;

  aboutToAppear(): void { this.appeared = true; }
  aboutToDisappear(): void { this.appeared = false; }

  private toast(message: ResourceStr): void {
    if (this.appeared && this.visible) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private checkedAtLabel(): ResourceStr {
    if (this.probe.failed) { return $r('app.string.dash_probe_checked_at_failed'); }
    return this.probe.stale ? $r('app.string.dash_probe_checked_at_stale') : $r('app.string.dash_probe_checked_at');
  }

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

  private async toggleHide(hidden: boolean): Promise<boolean> {
    if (!this.appeared || !this.visible || this.settings.saving || this.settings.hasDraft) { return false; }
    try {
      await this.settings.commit({ hideIp: hidden }, this.settings.revision);
      return true;
    } catch (e) {
      return false;
    }
  }

  private async copyExit(): Promise<void> {
    const result = this.probe.result;
    if (!this.appeared || !this.visible || this.copying || this.settings.hideIp || result === undefined) { return; }
    this.copying = true;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, result.ip));
      this.toast($r('app.string.copied'));
    } catch (e) {
      this.toast($r('app.string.dash_copy_failed'));
    } finally {
      this.copying = false;
    }
  }

  @Builder
  DetailField(field: DashboardExitDetailField) {
    Row({ space: 16 }) {
      Text(field.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(13)
        .lineHeight(18)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '38%' })
      if (field.loading) {
        Blank().layoutWeight(1)
        Row()
          .width(88)
          .height(18)
          .borderRadius(5)
          .backgroundColor(this.appStyle.palette.track)
          .opacity(0.55)
      } else {
        Text(field.content)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.End)
          .wordBreak(WordBreak.BREAK_ALL)
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .accessibilityDescription(field.retry ? uiResourceText(this.getUIContext(), $r('app.string.dash_retry_exit')) : '')
    .onClick((): void => {
      if (field.retry && this.appeared && this.visible && !this.probe.busy && !this.probe.qualityBusy) {
        this.onRefresh();
      }
    })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 16 }) {
            Column({ space: 6 }) {
              Text($r('app.string.exit_ip'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(13)
                .lineHeight(18)
                .fontColor($r('sys.color.font_secondary'))
              if (this.probe.result === undefined && this.probe.busy && !this.settings.hideIp) {
                Row()
                  .width('64%')
                  .height(24)
                  .borderRadius(6)
                  .backgroundColor(this.appStyle.palette.track)
                  .opacity(0.55)
                  .margin({ top: 2, bottom: 2 })
              } else {
                Text(this.address())
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(22)
                  .lineHeight(28)
                  .fontWeight(600)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                  .wordBreak(WordBreak.BREAK_ALL)
                  .copyOption(this.settings.hideIp ? CopyOptions.None : CopyOptions.LocalDevice)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            this.DetailField({ label: $r('app.string.region_label'), content: this.country(),
              loading: this.probe.result === undefined && this.probe.busy })
            this.DetailField({ label: $r('app.string.dash_ip_organization'), content: this.probe.result?.org || '—',
              loading: this.probe.result === undefined && this.probe.busy })
            this.DetailField({ label: $r('app.string.dash_ip_asn'), content: this.probe.result?.asn || '—',
              loading: this.probe.result === undefined && this.probe.busy })
            this.DetailField({ label: $r('app.string.dash_ip_type'),
              content: exitIpTypeLabel(this.probe.quality, false),
              loading: this.probe.quality === undefined && this.probe.qualityBusy })
            this.DetailField({ label: $r('app.string.dash_ip_quality'),
              content: this.probe.qualityFailed ? $r('app.string.dash_exit_failed') :
                exitIpQualityLabel(this.probe.quality, false),
              loading: this.probe.quality === undefined && this.probe.qualityBusy,
              retry: this.probe.qualityFailed })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .borderRadius(22)
          .backgroundColor(this.appStyle.palette.tileBackground)
          Column({ space: 16 }) {
            this.DetailField({ label: $r('app.string.dash_probe_source'), content: this.probe.result?.source || '—' })
            this.DetailField({ label: $r('app.string.dash_ip_quality_source'), content: this.probe.quality?.source || '—' })
            this.DetailField({ label: this.checkedAtLabel(), content: this.probe.result !== undefined ?
              new Date(this.probe.result.checkedAt).toLocaleString() : '—' })
            Row({ space: 16 }) {
              Text($r('app.string.dash_hide_ip'))
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(15)
                .lineHeight(20)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.hideIp })
                .enabled(this.visible && !this.settings.saving && !this.settings.hasDraft)
                .onChange((hidden: boolean): void => { this.toggleHide(hidden); })
            }
            .width('100%')
            .constraintSize({ minHeight: 40 })
          }
          .width('100%')
          .padding(16)
          .borderRadius(22)
          .backgroundColor(this.appStyle.palette.tileBackground)
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
        .fontFamily(this.appStyle.fontFamily)
        .width('100%')
        .height(40)
        .enabled(this.visible && !this.copying && !this.settings.hideIp && this.probe.result !== undefined)
        .onClick((): void => { this.copyExit(); })
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 24, left: PAGE_GUTTER, right: PAGE_GUTTER })
  }
}
