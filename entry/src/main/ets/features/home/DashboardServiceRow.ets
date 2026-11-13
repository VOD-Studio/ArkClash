import { ServiceAvailability, ServiceResult } from '../../client/ServiceCheck';
import { ServiceSlot, serviceInfo } from './Services';

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
    default: return $r('app.string.dash_unlock_unknown');
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
  @Param canUp: boolean = false;
  @Param canDown: boolean = false;
  @Event onToggle: (visible: boolean) => void = () => {};
  @Event onMove: (delta: number) => void = () => {};
  @Event onRun: () => void = () => {};

  private accessibleName(): string {
    const name = serviceInfo(this.slot.id)?.name ?? this.slot.id;
    if (typeof name === 'string') {
      return name;
    }
    try {
      return this.getUIContext().getHostContext()?.resourceManager.getStringSync(name.id) ?? this.slot.id;
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
      .borderRadius(20)
      .backgroundColor($r('app.color.service_icon_background'))
      Column({ space: 4 }) {
        Text(serviceInfo(this.slot.id)?.name ?? this.slot.id)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.slot.legacy) {
          Text($r('app.string.dash_legacy_service'))
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
        if (!this.managing) {
          Text(serviceConnectivityLabel(this.result, this.checking))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Text(serviceAvailabilityLabel(this.result?.availability ?? 'unknown'))
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
          if (this.result !== undefined) {
            Text(new Date(this.result.checkedAt).toLocaleTimeString())
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.managing) {
        Column({ space: 2 }) {
          Button('↑')
            .width(36)
            .height(32)
            .enabled(!this.saving && this.canUp)
            .accessibilityText($r('app.string.dash_move_up'))
            .onClick((): void => { this.onMove(-1); })
          Button('↓')
            .width(36)
            .height(32)
            .enabled(!this.saving && this.canDown)
            .accessibilityText($r('app.string.dash_move_down'))
            .onClick((): void => { this.onMove(1); })
        }
        Toggle({ type: ToggleType.Switch, isOn: this.slot.visible })
          .enabled(!this.saving && (!this.slot.visible || this.canDisable))
          .accessibilityText(this.accessibleName())
          .onChange((visible: boolean): void => { this.onToggle(visible); })
      } else {
        Button($r('app.string.dash_check'))
          .enabled(!this.checking && serviceInfo(this.slot.id) !== undefined)
          .onClick((): void => { this.onRun(); })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.tile_background'))
  }
}
