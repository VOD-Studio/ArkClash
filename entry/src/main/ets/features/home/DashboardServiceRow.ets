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
  @Event onToggle: (visible: boolean) => void = () => {};
  @Event onRun: () => void = () => {};

  private accessibleName(): string {
    try {
      return uiResourceText(this.getUIContext(), serviceInfo(this.slot.id)?.name ?? this.slot.id);
    } catch (error) {
      return this.slot.id;
    }
  }

  build() {
    Row({ space: 10 }) {
      Stack() {
        if (serviceInfo(this.slot.id) !== undefined) {
          Image(serviceInfo(this.slot.id)?.icon)
            .width(22)
            .height(22)
            .objectFit(ImageFit.Contain)
        } else {
          Text(this.slot.id.slice(0, 1).toUpperCase()).fontSize(18)
        }
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor($r('app.color.service_icon_background'))
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(serviceInfo(this.slot.id)?.name ?? this.slot.id)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (!this.managing && this.result !== undefined && this.result.availability !== 'unknown') {
            Text(serviceAvailabilityLabel(this.result.availability))
              .fontSize(12)
              .lineHeight(16)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        if (this.managing && this.shownOnDashboard) {
          Text($r('app.string.dash_service_shown'))
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_secondary'))
        }
        if (!this.managing) {
          Row({ space: 8 }) {
            Text(serviceConnectivityLabel(this.result, this.checking))
              .fontSize(12)
              .lineHeight(16)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            if (this.result !== undefined) {
              Text(new Date(this.result.checkedAt).toLocaleTimeString())
                .fontSize(11)
                .fontColor($r('sys.color.font_tertiary'))
                .lineHeight(14)
                .maxLines(1)
            }
          }
          .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.managing) {
        Toggle({ type: ToggleType.Switch, isOn: this.slot.visible })
          .enabled(!this.saving && (!this.slot.visible || this.canDisable))
          .accessibilityText(this.accessibleName())
          .onChange((visible: boolean): void => { this.onToggle(visible); })
      } else {
        Button({ type: ButtonType.Circle }) {
          if (this.checking) {
            LoadingProgress().width(18).height(18)
          } else {
            AppGlyph({ name: 'sync', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
          }
        }
        .width(32)
        .height(32)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText(uiResourceText(this.getUIContext(), $r('app.string.dash_check')))
        .enabled(!this.checking && serviceInfo(this.slot.id) !== undefined)
        .onClick((): void => { this.onRun(); })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 12, bottom: 12 })
    .borderRadius(22)
    .backgroundColor($r('app.color.tile_background'))
  }
}
