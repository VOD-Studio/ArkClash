import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { DashboardServiceRow, serviceConnectivityLabel } from './DashboardServiceRow';
import { DashboardServiceState } from './DashboardServiceState';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { serviceInfo, ServiceSlot } from './Services';

@ComponentV2
export struct DashboardServices {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileId: string = '';
  @Param routeRevision: string = '';
  @Local conn: Connection = connection;
  @Local settings: DashboardSettings = dashboardSettings;
  @Local state: DashboardServiceState = new DashboardServiceState();
  @Local exit: ExitIpProbe = exitIpProbe;
  @Local details: boolean = false;
  @Local managing: boolean = false;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.state.cancel();
  }

  @Monitor('visible', 'profileId', 'routeRevision', 'conn.routeRevision', 'conn.mode', 'conn.sessionMode', 'conn.forward',
    'conn.state')
  sync(): void {
    const route = `${this.profileId}:${this.routeRevision}:${this.conn.routeRevision}:${this.conn.mode}:` +
      `${this.conn.sessionMode}:${this.conn.forward}`;
    this.state.observe(this.context.filesDir, route, this.conn.connected, this.visible && !this.conn.busy);
    if (!this.visible) {
      this.details = false;
      this.managing = false;
    }
  }

  private enabledSlots(): ServiceSlot[] {
    return this.settings.services.filter((slot: ServiceSlot): boolean => slot.visible);
  }

  private enabledIds(): string[] {
    return this.enabledSlots().map((slot: ServiceSlot): string => slot.id);
  }

  private async setVisible(id: string, visible: boolean): Promise<void> {
    const slots = this.settings.services.map((slot: ServiceSlot): ServiceSlot => ({
      id: slot.id, visible: slot.id === id ? visible : slot.visible, legacy: slot.legacy, raw: slot.raw
    }));
    try {
      await this.settings.commit({ services: slots }, this.settings.revision);
    } catch (e) {
      this.toastFailure();
    }
  }

  private async move(from: number, to: number): Promise<void> {
    const slots = this.settings.services.slice();
    if (from < 0 || from >= slots.length || to < 0 || to >= slots.length || from === to) {
      return;
    }
    const moved = slots.splice(from, 1)[0];
    slots.splice(to, 0, moved);
    try {
      await this.settings.commit({ services: slots }, this.settings.revision);
    } catch (e) {
      this.toastFailure();
    }
  }

  private toastFailure(): void {
    this.getUIContext().getPromptAction().showToast({ message: this.settings.failure === 'lastService' ?
      $r('app.string.dash_service_keep_one') : $r('app.string.dash_save_failed') });
  }

  private run(ids: string[]): void {
    if (this.interactive) {
      this.state.run(ids);
    }
  }

  private exitAddress(): ResourceStr {
    if (this.settings.hideIp) {
      return '*****';
    }
    return this.exit.result?.ip ?? '—';
  }

  @Builder
  ServiceItem(slot: ServiceSlot) {
    DashboardServiceRow({
      slot: slot,
      result: this.state.results[slot.id],
      checking: this.state.busyIds.includes(slot.id),
      managing: this.managing,
      saving: this.settings.saving,
      canDisable: this.enabledSlots().length > 1,
      canUp: this.settings.services.findIndex((item: ServiceSlot): boolean => item.id === slot.id) > 0,
      canDown: this.settings.services.findIndex((item: ServiceSlot): boolean => item.id === slot.id) <
        this.settings.services.length - 1,
      onToggle: (visible: boolean): void => { this.setVisible(slot.id, visible); },
      onMove: (delta: number): void => {
        const from = this.settings.services.findIndex((item: ServiceSlot): boolean => item.id === slot.id);
        this.move(from, from + delta);
      },
      onRun: (): void => { this.run([slot.id]); }
    })
  }

  @Builder
  Details() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.exitAddress())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(this.conn.connected ? $r('app.string.dash_routed_exit') : $r('app.string.exit_local'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Text($r('app.string.dash_service_scope'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      Row({ space: 8 }) {
        Button(this.managing ? $r('app.string.dash_done') : $r('app.string.dash_service_manage'))
          .enabled(!this.state.busy)
          .onClick((): void => { this.managing = !this.managing; })
        Button(this.state.busy ? $r('app.string.action_cancel') : $r('app.string.dash_check_all'))
          .enabled(!this.managing && !this.conn.busy)
          .onClick((): void => {
            if (this.state.busy) { this.state.cancel(); } else { this.run(this.enabledIds()); }
          })
      }
      .width('100%')
      if (this.state.failed) {
        Text($r('app.string.dash_service_batch_failed'))
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
      }
      List({ space: 8 }) {
        if (this.managing) {
          ForEach(this.settings.services, (slot: ServiceSlot): void => {
            ListItem() { this.ServiceItem(slot) }
          }, (slot: ServiceSlot): string => `${slot.id}:${slot.visible}:manage`)
            .onMove((from: number, to: number): void => { this.move(from, to); })
        } else {
          ForEach(this.enabledSlots(), (slot: ServiceSlot): void => {
            ListItem() { this.ServiceItem(slot) }
          }, (slot: ServiceSlot): string => slot.id)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .enabled(!this.settings.saving)
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_services'), symbol: $r('sys.symbol.link'), chevron: true })
      Row({ space: 12 }) {
        ForEach(this.enabledSlots().slice(0, 2), (slot: ServiceSlot): void => {
          Column({ space: 6 }) {
            Stack() {
              if (serviceInfo(slot.id) !== undefined) {
                Image(serviceInfo(slot.id)?.icon)
                  .width(24)
                  .height(24)
                  .objectFit(ImageFit.Contain)
              } else {
                Text(slot.id.slice(0, 1).toUpperCase()).fontSize(18)
              }
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor($r('app.color.service_icon_background'))
            Text(serviceInfo(slot.id)?.name ?? slot.id)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(serviceConnectivityLabel(this.state.results[slot.id], this.state.busyIds.includes(slot.id)))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }, (slot: ServiceSlot): string => slot.id)
      }
      .width('100%')
      Text($r('app.string.dash_service_scope_short'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      Row({ space: 8 }) {
        Button($r('app.string.dash_service_details'))
          .enabled(this.interactive)
          .onClick((): void => { this.details = true; })
        Button(this.state.busy ? $r('app.string.action_cancel') : $r('app.string.dash_check'))
          .enabled(this.interactive && !this.conn.busy)
          .onClick((): void => {
            if (this.state.busy) {
              this.state.cancel();
            } else {
              this.run(this.enabledIds().slice(0, 2));
            }
          })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .bindSheet($$this.details, this.Details(), {
      title: { title: $r('app.string.card_services') }, detents: [SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: true,
      onDisappear: (): void => { this.managing = false; }
    })
  }
}
