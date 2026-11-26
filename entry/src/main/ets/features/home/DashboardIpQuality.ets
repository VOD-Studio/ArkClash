import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ExitIpQuality } from '../../client/ExitIpQuality';

export function exitIpTypeLabel(quality: ExitIpQuality | undefined, busy: boolean = false): ResourceStr {
  if (quality === undefined) {
    return busy ? $r('app.string.dash_ip_checking') : $r('app.string.dash_ip_type_unknown');
  }
  switch (quality.type) {
    case 'residential': return $r('app.string.dash_ip_residential');
    case 'mobile': return $r('app.string.dash_ip_mobile');
    case 'business': return $r('app.string.dash_ip_business');
    case 'hosting': return $r('app.string.dash_ip_hosting');
  }
}

export function exitIpQualityLabel(quality: ExitIpQuality | undefined, busy: boolean = false): ResourceStr {
  if (quality === undefined) {
    return busy ? $r('app.string.dash_ip_checking') : $r('app.string.dash_ip_quality_unknown');
  }
  switch (quality.level) {
    case 'good': return $r('app.string.dash_ip_quality_good');
    case 'normal': return $r('app.string.dash_ip_quality_normal');
    case 'risky': return $r('app.string.dash_ip_quality_risky');
  }
}

@ComponentV2
export struct DashboardIpQuality {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param quality: ExitIpQuality | undefined = undefined;
  @Param busy: boolean = false;

  private qualityTextColor(): ResourceColor {
    switch (this.quality?.level) {
      case 'good': return $r('app.color.success_foreground');
      case 'normal': return $r('app.color.warning');
      case 'risky': return $r('app.color.status_error');
      default: return $r('sys.color.font_secondary');
    }
  }

  private qualityBackgroundColor(): ResourceColor {
    switch (this.quality?.level) {
      case 'good': return $r('app.color.success_soft');
      case 'normal': return $r('app.color.warning_soft');
      case 'risky': return $r('app.color.error_soft');
      default: return this.appStyle.palette.tileBackground;
    }
  }

  @Builder
  Labels() {
    Row({ space: 6 }) {
      Text(exitIpTypeLabel(this.quality, this.busy))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(11)
        .fontWeight(500)
        .fontColor($r('sys.color.font_secondary'))
        .padding({ left: 9, right: 9 })
        .height(24)
        .constraintSize({ maxWidth: '48%' })
        .borderRadius(12)
        .backgroundColor(this.appStyle.palette.tileBackground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text() {
        Span($r('app.string.dash_ip_quality'))
          .fontFamily(this.appStyle.fontFamily)
        Span(' ')
          .fontFamily(this.appStyle.fontFamily)
        Span(exitIpQualityLabel(this.quality, this.busy))
          .fontFamily(this.appStyle.fontFamily)
      }
      .fontSize(11)
      .fontWeight(600)
      .fontColor(this.qualityTextColor())
      .padding({ left: 9, right: 9 })
      .height(24)
      .constraintSize({ maxWidth: '48%' })
      .borderRadius(12)
      .backgroundColor(this.qualityBackgroundColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(24)
  }

  build() {
    if (this.busy) {
      Row({ space: 6 }) {
        Row()
          .width('38%')
          .height(24)
          .borderRadius(12)
          .backgroundColor(this.appStyle.palette.track)
        Row()
          .width('44%')
          .height(24)
          .borderRadius(12)
          .backgroundColor(this.appStyle.palette.track)
      }
      .width('100%')
      .height(24)
      .opacity(0.55)
    } else {
      this.Labels()
    }
  }
}
