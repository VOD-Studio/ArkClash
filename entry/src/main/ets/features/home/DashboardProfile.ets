import { formatBytes } from '../../components/Format';
import { EmptyState } from '../../components/EmptyState';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

const DASHBOARD_DAY_MS = 24 * 60 * 60 * 1000;

@ComponentV2
export struct DashboardProfile {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileReady: boolean = false;
  @Param profileName: string = '';
  @Param profileUpdatedAt: number = 0;
  @Param profileUpdating: boolean = false;
  @Param profileUpdatable: boolean = true;
  @Param profileSource: string = '';
  @Param usedBytes: number = 0;
  @Param totalBytes: number = 0;
  @Param expireAt: number = 0;
  @Param groupCount: number = -1;
  @Param proxyCount: number = -1;
  @Param ruleCount: number = -1;
  @Event onAdd: () => void = () => {};
  @Event onOpen: () => void = () => {};
  @Event onSwitch: () => void = () => {};
  @Event onUpdate: () => void = () => {};
  @Local clock: number = Date.now();
  private timer: number = -1;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  @Monitor('visible')
  sync(): void {
    if (this.visible && this.timer === -1) {
      this.clock = Date.now();
      this.timer = setInterval((): void => { this.clock = Date.now(); }, 60000);
    } else if (!this.visible) {
      this.stopTimer();
    }
  }

  private stopTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private usedRatio(): number {
    return this.totalBytes > 0 ? Math.max(0, Math.min(1, this.usedBytes / this.totalBytes)) : 0;
  }

  private daysLeft(): number {
    return Math.max(0, Math.ceil((this.expireAt * 1000 - this.clock) / DASHBOARD_DAY_MS));
  }

  private source(): ResourceStr {
    if (this.profileSource === 'custom') {
      return $r('app.string.dash_profile_custom');
    }
    return this.profileUpdatable ? $r('app.string.dash_profile_subscription') : $r('app.string.profile_source_local');
  }

  @Builder
  Usage() {
    Column({ space: 8 }) {
      Row() {
        Text($r('app.string.dash_profile_usage', Math.round(this.usedRatio() * 100)))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.usedRatio() >= 0.9 ? $r('app.color.warning') : $r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(`${formatBytes(Math.max(0, this.usedBytes))} / ${formatBytes(this.totalBytes)}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Progress({ value: this.usedRatio() * 100, total: 100, type: ProgressType.Capsule })
        .width('100%')
        .height(8)
        .color(this.usedRatio() >= 0.9 ? $r('app.color.warning') : $r('app.color.brand'))
        .backgroundColor($r('app.color.track'))
    }
    .width('100%')
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_profile'), symbol: $r('sys.symbol.doc_text'), chevron: true })
      if (this.profileReady) {
        Text(this.profileName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => { if (this.interactive) { this.onOpen(); } })
        Text(this.source())
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        Text(this.profileUpdatedAt > 0 ? $r('app.string.dash_profile_updated',
          new Date(this.profileUpdatedAt).toLocaleString()) : '—')
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
        if (this.totalBytes > 0) {
          this.Usage()
        } else {
          Text($r('app.string.dash_profile_counts', this.groupCount >= 0 ? `${this.groupCount}` : '—',
            this.proxyCount >= 0 ? `${this.proxyCount}` : '—', this.ruleCount >= 0 ? `${this.ruleCount}` : '—'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
        if (this.expireAt > 0) {
          Text(this.expireAt * 1000 <= this.clock ? $r('app.string.usage_warn_expired') :
            $r('app.string.days_left', this.daysLeft()))
            .fontSize(12)
            .fontColor(this.daysLeft() <= 7 ? $r('app.color.warning') : $r('sys.color.font_secondary'))
        }
        Row({ space: 8 }) {
          Button($r('app.string.dash_profile_details'))
            .onClick((): void => { if (this.interactive) { this.onOpen(); } })
          Button($r('app.string.dash_profile_switch'))
            .onClick((): void => { if (this.interactive) { this.onSwitch(); } })
          if (this.profileUpdatable) {
            Button(this.profileUpdating ? $r('app.string.services_checking') : $r('app.string.action_update'))
              .enabled(!this.profileUpdating)
              .onClick((): void => { if (this.interactive) { this.onUpdate(); } })
          }
        }
        .enabled(this.interactive)
      } else {
        EmptyState({
          icon: $r('sys.symbol.doc_text'), title: $r('app.string.home_no_profile'),
          hint: $r('app.string.home_no_profile_hint'), actionLabel: $r('app.string.action_add_subscription'),
          onAction: (): void => { if (this.interactive) { this.onAdd(); } }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}
