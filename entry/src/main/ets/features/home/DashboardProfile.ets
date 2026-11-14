import { dashboardCount, dashboardTraffic, dashboardUpdatedAgo } from './DashboardFormat';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardUsageMeter } from './DashboardUsageMeter';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardFigure } from './DashboardFigure';
import { DashboardHeaderAction } from './DashboardHeaderAction';

const DASHBOARD_DAY_MS = 24 * 60 * 60 * 1000;

@ComponentV2
export struct DashboardProfile {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileReady: boolean = false;
  @Param canSwitchProfile: boolean = false;
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
    return Math.max(0, Math.floor((this.expireAt * 1000 - this.clock) / DASHBOARD_DAY_MS));
  }

  private source(): ResourceStr {
    if (this.profileSource === 'custom') {
      return $r('app.string.dash_profile_custom_type');
    }
    return this.profileUpdatable ? $r('app.string.dash_profile_remote') : $r('app.string.profile_source_local');
  }

  @Builder
  Usage() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text() {
          Span(`${Math.round(this.usedRatio() * 100)}%`)
            .fontSize(20)
            .fontWeight(600)
          Span(' ')
          Span($r('app.string.dash_used_short'))
            .fontSize(13)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
        }
        .lineHeight(25)
        .fontFeature('"tnum" on')
        Text(`${dashboardTraffic(Math.max(0, this.usedBytes))} / ${dashboardTraffic(this.totalBytes)}`)
          .fontSize(13)
          .lineHeight(18)
          .fontFeature('"tnum" on')
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      DashboardUsageMeter({ share: this.usedRatio() })
    }
    .width('100%')
  }


  build() {
    Column() {
      Row({ space: 8 }) {
        AppGlyph({ name: 'profiles', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
        Text($r('app.string.card_profile'))
          .fontSize(15)
          .lineHeight(20)
          .fontWeight(600)
          .layoutWeight(1)
        if (this.profileReady && this.profileUpdatable) {
          DashboardHeaderAction({ glyph: 'sync', actionLabel: $r('app.string.action_update'),
            busy: this.profileUpdating, active: this.interactive, onPress: (): void => { this.onUpdate(); } })
        }
        AppGlyph({ name: 'chevronForward', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
      }
      .width('100%')
      .constraintSize({ minHeight: 26 })
      Row() {
        Text(this.profileReady ? this.profileName : $r('app.string.action_add_subscription'))
          .fontSize(17)
          .lineHeight(22)
          .fontWeight(600)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.profileReady && this.canSwitchProfile) {
          Button({ type: ButtonType.Circle }) {
            AppGlyph({ name: 'swap', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
          }
          .width(28)
          .height(22)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .enabled(this.interactive)
          .accessibilityText($r('app.string.dash_profile_switch'))
          .hitTestBehavior(HitTestMode.Block)
          .onClick((): void => { this.onSwitch(); })
        }
      }
      .width('100%')
      .margin({ top: 12 })
      if (this.profileReady) {
        Row({ space: 12 }) {
          Text() {
            if (this.profileUpdatedAt > 0) {
              Span($r('app.string.dash_profile_updated_prefix'))
              Span(dashboardUpdatedAgo(this.profileUpdatedAt, this.clock))
            } else {
              Span('—')
            }
          }
            .accessibilityDescription(this.profileUpdatedAt > 0 ? new Date(this.profileUpdatedAt).toLocaleString() : '—')
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.expireAt > 0 ? $r('app.string.days_left', this.daysLeft()) : this.source())
            .fontSize(12)
            .lineHeight(16)
            .fontColor(this.expireAt > 0 && this.daysLeft() <= 7 ? $r('app.color.warning') :
              $r('sys.color.font_secondary'))
            .maxLines(1)
        }
        .width('100%')
        Column() {
          if (this.totalBytes > 0) {
            this.Usage()
          } else {
            Row({ space: 16 }) {
              DashboardFigure({ figureText: dashboardCount(this.groupCount),
                label: $r('app.string.card_group') })
              DashboardFigure({ figureText: dashboardCount(this.proxyCount),
                label: $r('app.string.tab_proxies') })
              DashboardFigure({ figureText: dashboardCount(this.ruleCount),
                label: $r('app.string.dash_rules') })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
        }
        .width('100%')
        .margin({ top: 14 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .onClick((): void => {
      if (this.interactive) {
        if (this.profileReady) { this.onOpen(); } else { this.onAdd(); }
      }
    })
  }
}
