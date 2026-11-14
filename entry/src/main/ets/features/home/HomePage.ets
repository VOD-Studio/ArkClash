import { common } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { curves, UIUtils } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { TabPage } from '../../components/TabPage';
import { CARD } from '../../components/Theme';
import { uiResourceText } from '../../components/ResourceText';
import { DashboardConnections } from './DashboardConnections';
import { DashboardGroups } from './DashboardGroups';
import { DashboardLan } from './DashboardLan';
import { dashboardCardDescription, dashboardCardGlyph, dashboardCardTitle, DASHBOARD_CARDS,
  dashboardCardMotionSeed, movedDashboardCards } from './DashboardLayout';
import { DashboardMemory } from './DashboardMemory';
import { DashboardMode } from './DashboardMode';
import { DashboardProfile } from './DashboardProfile';
import { DashboardServices } from './DashboardServices';
import { dashboardSettings, DashboardSettings } from './DashboardSettings';
import { DashboardSpeed } from './DashboardSpeed';
import { DashboardStatus } from './DashboardStatus';
import { DashboardVpn } from './DashboardVpn';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardEditMotion } from './DashboardEditMotion';

@ComponentV2
export struct HomePage {
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Param topInset: number = 0;
  @Param profileReady: boolean = false;
  @Param canSwitchProfile: boolean = false;
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
  @Param summaryGroupIcons: Record<string, string> = {};
  @Param usedBytes: number = 0;
  @Param totalBytes: number = 0;
  @Param expireAt: number = 0;
  @Param visible: boolean = false;
  @Param closeEditSignal: number = 0;
  @Event onAddProfile: () => void = () => {};
  @Event onOpenProfiles: () => void = () => {};
  @Event onOpenProfile: () => void = (): void => { this.onOpenProfiles(); };
  @Event onSwitchProfile: () => void = () => {};
  @Event onUpdateProfile: () => void = () => {};
  @Event onOpenProxies: () => void = () => {};
  @Event onEditingChanged: (editing: boolean) => void = () => {};
  @Local settings: DashboardSettings = dashboardSettings;
  @Local editing: boolean = false;
  @Local displayedCards: string[] = [];
  @Local reduceMotion: boolean = true;
  private readonly cardTransition: TransitionEffect = TransitionEffect.opacity(0)
    .combine(TransitionEffect.translate({ y: 8 }))
    .animation({ curve: curves.springMotion(0.3, 0.9) });
  private readonly controlTransition: TransitionEffect = TransitionEffect.opacity(0)
    .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
    .animation({ curve: curves.responsiveSpringMotion() });
  private reductionListener: (enabled: boolean) => void = (enabled: boolean): void => {
    this.reduceMotion = enabled;
  };
  private dragging: string = '';
  private appeared: boolean = false;
  private savingCards: boolean = false;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.appeared = true;
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.displayedCards = this.settings.cards;
    this.settings.load(this.context);
  }

  aboutToDisappear(): void {
    this.appeared = false;
    accessibility.offAnimationReduceStateChange(this.reductionListener);
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

  private setEditing(editing: boolean): void {
    if (!this.appeared || !this.visible || this.reduceMotion) {
      this.editing = editing;
      return;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.9) }, (): void => {
      this.editing = editing;
      UIUtils.flushUIUpdates();
    });
  }

  @Monitor('settings.cards')
  updateDisplayedCards(): void {
    if (!this.savingCards) {
      this.displayedCards = this.settings.cards;
    }
  }

  private presentCards(): void {
    const cards = this.settings.cards;
    if (!this.appeared || !this.visible || !this.editing || this.reduceMotion || this.displayedCards.length === 0) {
      this.displayedCards = cards;
      return;
    }
    // Monitor 不能同步刷新 UI；只在用户保存完成后提交呈现动画。
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.9) }, (): void => {
      this.displayedCards = cards;
      UIUtils.flushUIUpdates();
    });
  }

  private menus(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        label: this.editing ? $r('app.string.dash_done') : $r('app.string.dash_edit_cards'),
        icon: this.editing ? $r('sys.symbol.checkmark') : $r('sys.symbol.pencil_line'),
        isEnabled: this.settings.ready,
        action: (): void => { this.setEditing(!this.editing); }
      }
    }];
  }

  private async saveCards(cards: string[]): Promise<void> {
    if (!this.editing || this.settings.saving || this.savingCards) {
      return;
    }
    this.savingCards = true;
    try {
      await this.settings.commit({ cards: cards }, this.settings.revision);
    } catch (e) {
      if (this.appeared) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_save_failed') });
      }
    } finally {
      this.savingCards = false;
      this.presentCards();
    }
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
    if (this.settings.saving || this.savingCards) {
      return;
    }
    this.savingCards = true;
    try {
      await this.settings.retryDraft();
    } catch (e) {
      if (this.appeared) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_save_failed') });
      }
    } finally {
      this.savingCards = false;
      this.presentCards();
    }
  }


  @Builder
  AddCard(id: string) {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Circle }) {
        AppGlyph({ name: 'add', iconSize: 16, iconColor: Color.White })
      }
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor($r('app.color.brand'))
      .accessibilityText(uiResourceText(this.getUIContext(), dashboardCardTitle(id)))
      .onClick((): void => { this.saveCards([...this.settings.cards, id]); })
      Stack() {
        AppGlyph({ name: dashboardCardGlyph(id), iconSize: 20, iconColor: $r('sys.color.font_secondary') })
      }
      .width(40)
      .height(40)
      .borderRadius(14)
      .backgroundColor($r('app.color.card_background'))
      Column() {
        Text(dashboardCardTitle(id))
          .fontSize(15)
          .lineHeight(20)
          .fontWeight(600)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (dashboardCardDescription(id) !== '') {
          Text(dashboardCardDescription(id))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .height(64)
    .padding({ left: 12, right: 8 })
    .borderRadius(22)
    .backgroundColor($r('app.color.dash_addable_background'))
    .enabled(!this.settings.saving)
    .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.cardTransition)
  }

  @Builder
  EditableCard(id: string) {
    DashboardEditMotion({ active: this.editing && this.visible, seed: dashboardCardMotionSeed(id),
      reduceMotion: this.reduceMotion }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() { this.Card(id) }
          .width('100%')
          .enabled(!this.editing)
        if (this.editing && id !== 'status') {
          Button({ type: ButtonType.Circle }) {
            AppGlyph({ name: 'remove', iconSize: 16, iconColor: $r('app.color.status_error') })
          }
          .width(28)
          .height(28)
          .padding(0)
          .backgroundColor($r('app.color.dash_remove_background'))
          .enabled(!this.settings.saving)
          .accessibilityText($r('app.string.dash_remove'))
          .onClick((): void => {
            this.saveCards(this.settings.cards.filter((card: string): boolean => card !== id));
          })
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.controlTransition)
        }
      }
      .width('100%')
      .draggable(this.editing && !this.settings.saving)
      .onDragStart((): DragItemInfo => {
        this.dragging = id;
        return { extraInfo: id };
      })
      .onDragEnd((): void => { this.dragging = ''; })
      .onDrop((): void => { if (this.editing) { this.drop(id); } })
      .accessibilityDescription(uiResourceText(this.getUIContext(), this.editing ? $r('app.string.dash_drag_hint') : ''))
      .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.cardTransition)
    }
  }

  @Builder
  Card(id: string) {
    if (id === 'status') {
      DashboardStatus({ visible: this.visible, interactive: !this.editing, profileReady: this.profileReady,
        profileId: this.profileId, routeRevision: this.routeRevision, motionEnabled: this.visible && !this.reduceMotion })
    } else if (id === 'speed') {
      DashboardSpeed({ visible: this.visible })
    } else if (id === 'mode') {
      DashboardMode({ interactive: !this.editing, motionEnabled: this.visible && !this.reduceMotion })
    } else if (id === 'profile') {
      DashboardProfile({
        visible: this.visible, interactive: !this.editing, profileReady: this.profileReady, profileName: this.profileName,
        canSwitchProfile: this.canSwitchProfile,
        profileUpdatedAt: this.profileUpdatedAt, profileUpdating: this.profileUpdating,
        profileUpdatable: this.profileUpdatable, profileSource: this.profileSource, usedBytes: this.usedBytes,
        totalBytes: this.totalBytes, expireAt: this.expireAt, groupCount: this.profileReady ? this.summaryGroups.length : -1,
        proxyCount: this.profileProxyCount, ruleCount: this.profileRuleCount,
        onAdd: (): void => { this.onAddProfile(); }, onOpen: (): void => { this.onOpenProfile(); },
        onSwitch: (): void => { this.onSwitchProfile(); }, onUpdate: (): void => { this.onUpdateProfile(); }
      })
    } else if (id === 'groups') {
      DashboardGroups({ visible: this.visible, interactive: !this.editing, profileReady: this.profileReady,
        profileId: this.profileId, routeRevision: this.routeRevision, summaryGroups: this.summaryGroups,
        summaryGroupIcons: this.summaryGroupIcons,
        onOpen: (): void => { this.onOpenProxies(); } })
    } else if (id === 'vpn') {
      DashboardVpn({ visible: this.visible, interactive: !this.editing })
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

  @Builder
  DashboardContent() {
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
        Column({ space: 8 }) {
          ForEach(this.displayedCards, (id: string): void => {
            this.EditableCard(id)
          }, (id: string): string => id)
          if (this.editing && this.availableCards().length > 0) {
            Column({ space: 8 }) {
              Text($r('app.string.dash_add_cards'))
                .fontSize(13)
                .fontWeight(600)
                .fontColor($r('sys.color.font_secondary'))
                .padding({ left: 8, top: 4, right: 8, bottom: 10 })
              ForEach(this.availableCards(), (id: string): void => {
                this.AddCard(id)
              }, (id: string): string => id)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 14 })
            .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.controlTransition)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 560 })
      } else if (this.settings.failure === '') {
        LoadingProgress().width(32).height(32)
      }
    }

  build() {
    TabPage({ title: this.editing ? $r('app.string.dash_edit_cards') : $r('app.string.tab_home'),
      topInset: this.topInset, scroller: this.scroller, content: (): void => this.DashboardContent(),
      menus: this.menus(), onScrollDirection: (down: boolean): void => { this.onScrollDirection(down); } })
  }
}
