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
  @Param quality: ExitIpQuality | undefined = undefined;
  @Param busy: boolean = false;

  private qualityColor(): ResourceColor {
    switch (this.quality?.level) {
      case 'good': return $r('app.color.status_connected');
      case 'risky': return $r('app.color.status_error');
      default: return $r('sys.color.font_secondary');
    }
  }

  @Builder
  Labels() {
    Row({ space: 6 }) {
      Text(exitIpTypeLabel(this.quality, this.busy))
        .fontSize(10.5)
        .fontWeight(500)
        .fontColor($r('sys.color.font_secondary'))
        .padding({ left: 7, right: 7 })
        .height(24)
        .constraintSize({ maxWidth: '48%' })
        .borderRadius(7)
        .backgroundColor($r('app.color.tile_background'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text() {
        Span($r('app.string.dash_ip_quality'))
        Span(' ')
        Span(exitIpQualityLabel(this.quality, this.busy))
      }
      .fontSize(10.5)
      .fontWeight(500)
      .fontColor(this.qualityColor())
      .padding({ left: 7, right: 7 })
      .height(24)
      .constraintSize({ maxWidth: '48%' })
      .borderRadius(7)
      .backgroundColor(this.quality?.level === 'good' ? $r('app.color.success_soft') :
        this.quality?.level === 'risky' ? $r('app.color.warning_soft') : $r('app.color.tile_background'))
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
          .borderRadius(7)
          .backgroundColor($r('app.color.track'))
        Row()
          .width('44%')
          .height(24)
          .borderRadius(7)
          .backgroundColor($r('app.color.track'))
      }
      .width('100%')
      .height(24)
      .opacity(0.55)
    } else {
      this.Labels()
    }
  }
}
