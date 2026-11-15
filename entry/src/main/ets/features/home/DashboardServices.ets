import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { exitIpProbe, ExitIpProbe } from '../../client/ExitIp';
import { DASHBOARD_CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { uiResourceText } from '../../components/ResourceText';
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

  @Monitor('visible', 'interactive', 'details', 'managing', 'settings.ready', 'settings.revision', 'profileId',
    'routeRevision', 'conn.routeRevision', 'conn.mode', 'conn.modePending', 'conn.sessionMode', 'conn.forward', 'conn.state')
  sync(): void {
    const route = `${this.profileId}:${this.routeRevision}:${this.conn.routeRevision}:${this.conn.mode}:` +
      `${this.conn.sessionMode}:${this.conn.forward}`;
    const ids = this.enabledIds();
    this.state.observe(this.context.filesDir, route, this.conn.connected,
      this.visible && this.interactive && this.settings.ready && !this.conn.busy && !this.conn.modePending && !this.managing,
      this.details ? ids : ids.slice(0, 4));
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
      // 首页统一消费 settings.failure，抽屉不重复提示。
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
    }
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
      shownOnDashboard: this.enabledIds().slice(0, 4).includes(slot.id),
      onToggle: (visible: boolean): void => { this.setVisible(slot.id, visible); },
      onRun: (): void => { this.run([slot.id]); }
    })
  }

  @Builder
  Details() {
    Column({ space: 12 }) {
      if (!this.managing) {
        Row({ space: 8 }) {
          Text(this.exitAddress())
            .fontSize(16)
            .fontWeight(600)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.conn.connected ? $r('app.string.dash_routed_exit') : $r('app.string.exit_local'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(12)
        .borderRadius(22)
        .backgroundColor($r('app.color.tile_background'))
      }
      Row({ space: 8 }) {
        Button(this.managing ? $r('app.string.dash_done') : $r('app.string.dash_service_manage'))
          .layoutWeight(1)
          .height(40)
          .enabled(!this.state.busy)
          .onClick((): void => { this.managing = !this.managing; })
        if (!this.managing) {
          Button(this.state.busy ? $r('app.string.action_cancel') : $r('app.string.dash_check_all'))
            .layoutWeight(1)
            .height(40)
            .enabled(!this.conn.busy)
            .onClick((): void => {
              if (this.state.busy) { this.state.cancel(); } else { this.run(this.enabledIds()); }
            })
        }
      }
      .width('100%')
      if (this.state.failed && !this.managing) {
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
    .alignItems(HorizontalAlign.Start)
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_services'), glyph: 'verified', chevron: true })
      Column({ space: 8 }) {
        ForEach([0, 2], (first: number): void => {
          if (first < this.enabledSlots().length) {
            Row({ space: 8 }) {
              ForEach(this.enabledSlots().slice(first, first + 2), (slot: ServiceSlot): void => {
                Row({ space: 8 }) {
                  Stack({ alignContent: Alignment.BottomEnd }) {
                    Stack() {
                      if (serviceInfo(slot.id) !== undefined) {
                        Image(serviceInfo(slot.id)?.icon)
                          .width(18)
                          .height(18)
                          .objectFit(ImageFit.Contain)
                      } else {
                        Text(slot.id.slice(0, 1).toUpperCase()).fontSize(14)
                      }
                    }
                    .width(30)
                    .height(30)
                    .borderRadius(9)
                    .backgroundColor($r('app.color.service_icon_background'))
                    Circle({ width: 7, height: 7 })
                      .fill(this.state.busyIds.includes(slot.id) ? $r('sys.color.font_tertiary') :
                        this.state.results[slot.id]?.reachability === 'reachable' ? $r('app.color.status_connected') :
                        this.state.results[slot.id] === undefined ? $r('sys.color.font_tertiary') : $r('app.color.warning'))
                      .stroke($r('app.color.tile_background'))
                      .strokeWidth(2)
                  }
                  Text(serviceConnectivityLabel(this.state.results[slot.id], this.state.busyIds.includes(slot.id)))
                    .fontSize(12)
                    .lineHeight(16)
                    .fontWeight(600)
                    .fontFeature('"tnum" on')
                    .fontColor(this.state.results[slot.id]?.reachability === 'reachable' ? $r('app.color.status_connected') :
                      $r('sys.color.font_secondary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .layoutWeight(1)
                .height(44)
                .padding({ left: 7, right: 12 })
                .borderRadius(16)
                .backgroundColor($r('app.color.tile_background'))
                .accessibilityText(uiResourceText(this.getUIContext(), serviceInfo(slot.id)?.name ?? slot.id))
              }, (slot: ServiceSlot): string => slot.id)
            }
            .width('100%')
          }
        }, (first: number): string => first.toString())
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details, {
      title: { title: this.managing ? $r('app.string.dash_service_manage') : $r('app.string.card_services') },
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: true,
      onDisappear: (): void => { this.managing = false; }
    })
  }
}
