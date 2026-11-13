import { common } from '@kit.AbilityKit';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { TabPage } from '../../components/TabPage';
import { CARD } from '../../components/Theme';
import { DashboardConnections } from './DashboardConnections';
import { DashboardGroups } from './DashboardGroups';
import { DashboardLan } from './DashboardLan';
import { dashboardCardTitle, DASHBOARD_CARDS, movedDashboardCards } from './DashboardLayout';
import { DashboardMemory } from './DashboardMemory';
import { DashboardMode } from './DashboardMode';
import { DashboardProfile } from './DashboardProfile';
import { DashboardServices } from './DashboardServices';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { DashboardSpeed } from './DashboardSpeed';
import { DashboardStatus } from './DashboardStatus';
import { DashboardVpn } from './DashboardVpn';

@ComponentV2
export struct HomePage {
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Param topInset: number = 0;
  @Param profileReady: boolean = false;
  @Param profileId: string = '';
  @Param profileName: string = '';
  @Param profileUpdatedAt: number = 0;
  @Param profileUpdating: boolean = false;
  @Param profileUpdatable: boolean = true;
  @Param profileSource: string = '';
  @Param profileProxyCount: number = -1;
  @Param profileRuleCount: number = -1;
  @Param routeRevision: string = '';
  @Param summaryGroups: string[] = [];
  @Param usedBytes: number = 0;
  @Param totalBytes: number = 0;
  @Param expireAt: number = 0;
  @Param visible: boolean = false;
  @Param closeEditSignal: number = 0;
  @Event onAddProfile: () => void = () => {};
  @Event onOpenProfiles: () => void = () => {};
  @Event onOpenProfile: () => void = (): void => { this.onOpenProfiles(); };
  @Event onUpdateProfile: () => void = () => {};
  @Event onOpenProxies: () => void = () => {};
  @Event onEditingChanged: (editing: boolean) => void = () => {};
  @Local settings: DashboardSettings = dashboardSettings;
  @Local editing: boolean = false;
  private dragging: string = '';
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.settings.load(this.context);
  }

  aboutToDisappear(): void {
    this.onEditingChanged(false);
  }

  @Monitor('closeEditSignal')
  closeEditing(): void {
    this.editing = false;
  }

  @Monitor('editing')
  editingChanged(): void {
    this.onEditingChanged(this.editing);
  }

  private menus(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        label: this.editing ? $r('app.string.dash_done') : $r('app.string.dash_edit_cards'),
        icon: this.editing ? $r('sys.symbol.checkmark') : $r('sys.symbol.pencil_line'),
        isEnabled: this.settings.ready,
        action: (): void => { this.editing = !this.editing; }
      }
    }];
  }

  private async saveCards(cards: string[]): Promise<void> {
    if (!this.editing || this.settings.saving) {
      return;
    }
    try {
      await this.settings.commit({ cards: cards }, this.settings.revision);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_save_failed') });
    }
  }

  private move(id: string, delta: number): void {
    const from = this.settings.cards.indexOf(id);
    this.saveCards(movedDashboardCards(this.settings.cards, from, from + delta));
  }

  private drop(target: string): void {
    if (this.dragging === '' || this.dragging === target) {
      return;
    }
    this.saveCards(movedDashboardCards(this.settings.cards, this.settings.cards.indexOf(this.dragging),
      this.settings.cards.indexOf(target)));
    this.dragging = '';
  }

  private availableCards(): string[] {
    return DASHBOARD_CARDS.filter((id: string): boolean => !this.settings.cards.includes(id));
  }

  private async retrySave(): Promise<void> {
    try {
      await this.settings.retryDraft();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_save_failed') });
    }
  }

  @Builder
  Editor(id: string) {
    Row({ space: 6 }) {
      Text(dashboardCardTitle(id))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
        .draggable(true)
        .onDragStart((): DragItemInfo => {
          this.dragging = id;
          return { extraInfo: id };
        })
        .onDragEnd((): void => { this.dragging = ''; })
        .accessibilityDescription($r('app.string.dash_drag_hint'))
      Button('↑')
        .width(36)
        .height(32)
        .enabled(this.settings.cards.indexOf(id) > 0)
        .accessibilityText($r('app.string.dash_move_up'))
        .onClick((): void => { this.move(id, -1); })
      Button('↓')
        .width(36)
        .height(32)
        .enabled(this.settings.cards.indexOf(id) < this.settings.cards.length - 1)
        .accessibilityText($r('app.string.dash_move_down'))
        .onClick((): void => { this.move(id, 1); })
      if (id !== 'status') {
        Button($r('app.string.dash_remove'))
          .height(32)
          .onClick((): void => { this.saveCards(this.settings.cards.filter((card: string): boolean => card !== id)); })
      }
    }
    .width('100%')
    .enabled(!this.settings.saving)
  }

  @Builder
  Card(id: string) {
    if (id === 'status') {
      DashboardStatus({ visible: this.visible, interactive: !this.editing, profileReady: this.profileReady,
        profileId: this.profileId, routeRevision: this.routeRevision })
    } else if (id === 'speed') {
      DashboardSpeed({ visible: this.visible })
    } else if (id === 'mode') {
      DashboardMode({ interactive: !this.editing })
    } else if (id === 'profile') {
      DashboardProfile({
        visible: this.visible, interactive: !this.editing, profileReady: this.profileReady, profileName: this.profileName,
        profileUpdatedAt: this.profileUpdatedAt, profileUpdating: this.profileUpdating,
        profileUpdatable: this.profileUpdatable, profileSource: this.profileSource, usedBytes: this.usedBytes,
        totalBytes: this.totalBytes, expireAt: this.expireAt, groupCount: this.profileReady ? this.summaryGroups.length : -1,
        proxyCount: this.profileProxyCount, ruleCount: this.profileRuleCount,
        onAdd: (): void => { this.onAddProfile(); }, onOpen: (): void => { this.onOpenProfile(); },
        onSwitch: (): void => { this.onOpenProfiles(); }, onUpdate: (): void => { this.onUpdateProfile(); }
      })
    } else if (id === 'groups') {
      DashboardGroups({ visible: this.visible, interactive: !this.editing, profileReady: this.profileReady,
        profileId: this.profileId, routeRevision: this.routeRevision, summaryGroups: this.summaryGroups,
        onOpen: (): void => { this.onOpenProxies(); } })
    } else if (id === 'vpn') {
      DashboardVpn()
    } else if (id === 'services') {
      DashboardServices({ visible: this.visible, interactive: !this.editing, profileId: this.profileId,
        routeRevision: this.routeRevision })
    } else if (id === 'connections') {
      DashboardConnections({ visible: this.visible, interactive: !this.editing })
    } else if (id === 'lan') {
      DashboardLan({ visible: this.visible, interactive: !this.editing, routeRevision: this.routeRevision })
    } else if (id === 'memory') {
      DashboardMemory({ visible: this.visible, interactive: !this.editing })
    }
  }

  build() {
    TabPage({ title: $r('app.string.tab_home'), topInset: this.topInset, scroller: this.scroller,
      menus: this.menus(), onScrollDirection: (down: boolean): void => { this.onScrollDirection(down); } }) {
      if (this.settings.failure !== '') {
        Column({ space: 8 }) {
          Text(this.settings.failure === 'conflict' ? $r('app.string.dash_save_conflict') :
            $r('app.string.dash_save_failed'))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
          if (this.settings.hasDraft) {
            Button($r('app.string.dash_retry_save'))
              .enabled(!this.settings.saving)
              .onClick((): void => { this.retrySave(); })
          } else if (!this.settings.ready) {
            Button($r('app.string.dash_retry'))
              .onClick((): void => { this.settings.load(this.context); })
          }
        }
        .attributeModifier(CARD)
      }
      if (this.settings.ready) {
        ForEach(this.settings.cards, (id: string): void => {
          Column({ space: 8 }) {
            if (this.editing) {
              this.Editor(id)
            }
            Column() { this.Card(id) }
              .width('100%')
              .enabled(!this.editing)
          }
          .width('100%')
          .onDrop((): void => { if (this.editing) { this.drop(id); } })
        }, (id: string): string => id)
        if (this.editing) {
          Column({ space: 10 }) {
            Text($r('app.string.dash_add_cards'))
              .fontWeight(FontWeight.Medium)
            ForEach(this.availableCards(), (id: string): void => {
              Button(dashboardCardTitle(id))
                .width('100%')
                .enabled(!this.settings.saving)
                .onClick((): void => { this.saveCards([...this.settings.cards, id]); })
            }, (id: string): string => id)
            Text($r('app.string.dash_edit_hint'))
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .attributeModifier(CARD)
        }
      } else if (this.settings.failure === '') {
        LoadingProgress().width(32).height(32)
      }
    }
  }
}
