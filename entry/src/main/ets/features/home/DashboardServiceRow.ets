import { ServiceAvailability, ServiceResult } from '../../client/ServiceCheck';
import { uiResourceText } from '../../components/ResourceText';
import { ServiceSlot, serviceInfo } from './Services';
import { AppGlyph } from '../../components/AppGlyph';

export function serviceAvailabilityLabel(status: ServiceAvailability): ResourceStr {
  switch (status) {
    case 'available': return $r('app.string.dash_unlock_available');
    case 'restricted': return $r('app.string.dash_unlock_restricted');
    case 'unavailable': return $r('app.string.dash_unlock_unavailable');
    case 'disallowed-isp': return $r('app.string.dash_unlock_isp');
    case 'blocked': return $r('app.string.dash_unlock_blocked');
    case 'unsupported-region': return $r('app.string.dash_unlock_region');
    case 'originals-only': return $r('app.string.dash_unlock_originals');
    case 'coming-soon': return $r('app.string.dash_unlock_soon');
    case 'timeout': return $r('app.string.dash_unlock_timeout');
    case 'failed': return $r('app.string.dash_unlock_failed');
    default: return '—';
  }
}

export function serviceConnectivityLabel(result: ServiceResult | undefined, checking: boolean): ResourceStr {
  if (checking) {
    return $r('app.string.services_checking');
  }
  if (result === undefined) {
    return $r('app.string.dash_service_untested');
  }
  if (result.failure === 'capacity') {
    return $r('app.string.dash_probe_busy');
  }
  if (result.controlStatus > 0 || result.failure === 'controller' || result.failure === 'invalidResponse') {
    return result.failure === 'timeout' ? $r('app.string.dash_probe_timeout') : $r('app.string.dash_probe_failed');
  }
  switch (result.reachability) {
    case 'reachable': return $r('app.string.dash_service_reachable', result.delay);
    case 'restricted': return $r('app.string.dash_service_restricted', result.httpCode);
    case 'timeout': return $r('app.string.dash_service_timeout');
    case 'unreachable': return $r('app.string.dash_service_unreachable', result.httpCode);
    default: return $r('app.string.dash_service_failed');
  }
}

@ComponentV2
export struct DashboardServiceRow {
  @Param slot: ServiceSlot = { id: '', visible: false, legacy: false, raw: {} };
  @Param result: ServiceResult | undefined = undefined;
  @Param checking: boolean = false;
  @Param managing: boolean = false;
  @Param saving: boolean = false;
  @Param canDisable: boolean = true;
  @Param shownOnDashboard: boolean = false;
  @Param failed: boolean = false;
  @Param canRun: boolean = true;
  @Event onToggle: (visible: boolean) => void = () => {};
  @Event onRun: () => void = () => {};

  private accessibleName(): string {
    try {
      return uiResourceText(this.getUIContext(), serviceInfo(this.slot.id)?.name ?? this.slot.id);
    } catch (error) {
      return this.slot.id;
    }
  }

  private statusLabel(): ResourceStr {
    return this.failed && this.result === undefined && !this.checking ?
      $r('app.string.dash_probe_failed') : serviceConnectivityLabel(this.result, this.checking);
  }

  private statusColor(): ResourceColor {
    if (this.result === undefined) {
      return this.failed ? $r('app.color.status_error') : $r('sys.color.font_tertiary');
    }
    if (this.result.reachability === 'reachable') {
      return $r('app.color.success_foreground');
    }
    return this.result.reachability === 'restricted' || this.result.failure === 'capacity' ?
      $r('app.color.warning') : $r('app.color.status_error');
  }

  @Builder
  Content() {
    Row({ space: 12 }) {
      Stack() {
        if (serviceInfo(this.slot.id) !== undefined) {
          Image(serviceInfo(this.slot.id)?.icon)
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
        } else {
          Text(this.slot.id.slice(0, 1).toUpperCase()).fontSize(18)
        }
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor($r('app.color.service_icon_background'))
      Column({ space: 2 }) {
        Text(serviceInfo(this.slot.id)?.name ?? this.slot.id)
          .fontSize(16)
          .lineHeight(22)
          .fontWeight(500)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.managing) {
          Text(this.shownOnDashboard ? $r('app.string.dash_service_shown') : '')
            .fontSize(11)
            .lineHeight(16)
            .height(16)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
        } else if (this.result !== undefined && this.result.availability !== 'unknown') {
          Text(serviceAvailabilityLabel(this.result.availability))
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      if (this.managing) {
        Toggle({ type: ToggleType.Switch, isOn: this.slot.visible })
          .enabled(!this.saving && (!this.slot.visible || this.canDisable))
          .accessibilityText(this.accessibleName())
          .onChange((visible: boolean): void => { this.onToggle(visible); })
        AppGlyph({ name: 'sort', iconSize: 18, iconColor: $r('sys.color.font_tertiary') })
      } else {
        Stack({ alignContent: Alignment.End }) {
          if (this.checking) {
            LoadingProgress().width(20).height(20).color($r('app.color.brand'))
          } else {
            Text(this.statusLabel())
              .fontSize(12)
              .lineHeight(16)
              .fontWeight(500)
              .fontFeature('"tnum" on')
              .fontColor(this.statusColor())
              .textAlign(TextAlign.End)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .width(108)
        .height(32)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 12, bottom: 12 })
    .constraintSize({ minHeight: 64 })
  }

  build() {
    if (this.managing) {
      this.Content()
    } else {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        this.Content()
      }
      .width('100%')
      .padding(0)
      .borderRadius(16)
      .stateStyles({ disabled: { .opacity(1) } })
      .enabled(this.canRun && serviceInfo(this.slot.id) !== undefined)
      .accessibilityText(this.accessibleName())
      .accessibilityDescription(uiResourceText(this.getUIContext(), this.statusLabel()))
      .onClick((): void => { this.onRun(); })
    }
  }
}
