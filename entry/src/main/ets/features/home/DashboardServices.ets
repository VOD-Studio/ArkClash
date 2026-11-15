import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { AppGlyph } from '../../components/AppGlyph';
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
  @Local details: boolean = false;
  @Local managing: boolean = false;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private manualGeneration: number = 0;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.manualGeneration++;
    this.state.cancel();
  }

  @Monitor('visible', 'interactive', 'details', 'managing', 'settings.ready', 'settings.revision', 'profileId',
    'routeRevision', 'conn.routeRevision', 'conn.mode', 'conn.modePending', 'conn.sessionMode', 'conn.forward', 'conn.state')
  sync(): void {
    this.manualGeneration++;
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
    if (this.settings.saving || this.settings.hasDraft) { return; }
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
    if (this.settings.saving || this.settings.hasDraft) { return; }
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

  private async run(ids: string[]): Promise<void> {
    if (!this.visible || !this.details || !this.interactive || this.conn.busy || this.conn.modePending || this.state.busy) {
      return;
    }
    const generation = ++this.manualGeneration;
    await this.state.run(ids);
    if (generation === this.manualGeneration && this.visible && this.details && this.state.failed) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_probe_failed') });
    }
  }


  @Builder
  ServiceItem(slot: ServiceSlot) {
    DashboardServiceRow({
      slot: slot,
      result: this.state.results[slot.id],
      checking: this.state.busy && (this.state.busyIds.includes(slot.id) || this.state.results[slot.id] === undefined),
      failed: this.state.failed,
      canRun: !this.state.busy && !this.conn.busy && !this.conn.modePending,
      managing: this.managing,
      saving: this.settings.saving || this.settings.hasDraft,
      canDisable: this.enabledSlots().length > 1,
      shownOnDashboard: this.enabledIds().slice(0, 4).includes(slot.id),
      onToggle: (visible: boolean): void => { this.setVisible(slot.id, visible); },
      onRun: (): void => { this.run([slot.id]); }
    })
  }

  @Builder
  SheetHeader() {
    Row({ space: 8 }) {
      Text(this.managing ? $r('app.string.dash_service_manage') : $r('app.string.card_services'))
        .fontSize(20)
        .lineHeight(26)
        .fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (!this.managing) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
          if (this.state.busy) {
            LoadingProgress().width(22).height(22).color($r('app.color.brand'))
              .hitTestBehavior(HitTestMode.None)
          } else {
            AppGlyph({ name: 'sync', iconSize: 22, iconColor: $r('sys.color.font_primary') })
          }
        }
        .width(40).height(40).padding(0)
        .enabled(!this.conn.busy && !this.conn.modePending)
        .accessibilityText(this.state.busy ? $r('app.string.action_cancel') : $r('app.string.dash_check_all'))
        .onClick((): void => {
          if (this.state.busy) {
            this.manualGeneration++;
            this.state.cancel();
          } else {
            this.run(this.enabledIds());
          }
        })
      }
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        AppGlyph({ name: this.managing ? 'check' : 'edit', iconSize: 22,
          iconColor: this.managing ? $r('app.color.brand') : $r('sys.color.font_primary') })
      }
      .width(40).height(40).padding(0)
      .enabled(!this.settings.saving && !this.settings.hasDraft)
      .accessibilityText(this.managing ? $r('app.string.dash_done') : $r('app.string.dash_service_manage'))
      .onClick((): void => { this.managing = !this.managing; })
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        AppGlyph({ name: 'close', iconSize: 22, iconColor: $r('sys.color.font_primary') })
      }
      .width(40).height(40).padding(0)
      .accessibilityText($r('app.string.action_close'))
      .onClick((): void => { this.details = false; })
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
  }

  @Builder
  Details() {
    Column({ space: 8 }) {
      this.SheetHeader()
      List({ space: 0 }) {
        if (this.managing) {
          ForEach(this.settings.services, (slot: ServiceSlot): void => {
            ListItem() { this.ServiceItem(slot) }
          }, (slot: ServiceSlot): string => `${slot.id}:${slot.visible}`)
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
      .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 64, endMargin: 16 })
      .enabled(!this.settings.saving && !this.settings.hasDraft)
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
                        this.state.results[slot.id] === undefined && !this.state.failed ?
                          $r('sys.color.font_tertiary') : $r('app.color.warning'))
                      .stroke($r('app.color.tile_background'))
                      .strokeWidth(2)
                  }
                  Text(this.state.failed && this.state.results[slot.id] === undefined ? $r('app.string.dash_probe_failed') :
                    serviceConnectivityLabel(this.state.results[slot.id], this.state.busyIds.includes(slot.id)))
                    .fontSize(12)
                    .lineHeight(16)
                    .fontWeight(600)
                    .fontFeature('"tnum" on')
                    .fontColor(this.state.results[slot.id]?.reachability === 'reachable' ? $r('app.color.success_foreground') :
                      $r('sys.color.font_secondary'))
                    .maxLines(1)
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
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(), showClose: false,
      onDisappear: (): void => { this.managing = false; }
    })
  }
}
