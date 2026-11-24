import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { curves, UIUtils } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { TabPage } from '../../components/TabPage';
import { uiResourceText } from '../../components/ResourceText';
import { DiagnosticFeedTarget } from '../../client/Diagnostics';
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
import { DashboardLiveStatus } from './DashboardLiveStatus';

@ComponentV2
export struct HomePage {
  @Local private appStyle: AppearanceState = appAppearance;
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
  @Event onOpenResources: () => void = () => {};
  @Event onOpenDiagnostic: (target: DiagnosticFeedTarget) => void = (_target: DiagnosticFeedTarget): void => {};
  @Event onEditingChanged: (editing: boolean) => void = () => {};
  @Local settings: DashboardSettings = dashboardSettings;
  @Local editing: boolean = false;
  @Local displayedCards: string[] = [];
  @Local reduceMotion: boolean = true;
  @Local loadingSettings: boolean = false;
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
  private recoveryShown: boolean = false;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.appeared = true;
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.displayedCards = this.settings.cards;
    this.loadSettings();
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

  @Monitor('settings.failure')
  settingsFailureChanged(): void {
    if (!this.appeared || !this.visible || this.settings.failure === '') { return; }
    this.getUIContext().getPromptAction().showToast({ message: this.settings.failure === 'conflict' ?
      $r('app.string.dash_save_conflict') : this.settings.failure === 'lastService' ?
      $r('app.string.dash_service_keep_one') : $r('app.string.dash_save_failed') });
  }

  private async loadSettings(): Promise<void> {
    if (this.settings.ready || this.loadingSettings) { return; }
    this.loadingSettings = true;
    try {
      await this.settings.load(this.context);
    } finally {
      this.loadingSettings = false;
    }
  }

  private editCards(): void {
    if (!this.appeared || !this.visible || this.settings.saving || this.loadingSettings) { return; }
    if (!this.settings.ready) { this.loadSettings(); return; }
    if (this.settings.hasDraft) { this.recoverDraft(); return; }
    this.editing = !this.editing;
  }

  private recoverDraft(): void {
    if (this.recoveryShown) { return; }
    this.recoveryShown = true;
    const nextEditing = !this.editing;
    let choice: 'retry' | 'discard' | undefined = undefined;
    this.getUIContext().showActionSheet({
      title: $r('app.string.profile_unsaved_title'),
      message: this.settings.failure === 'conflict' ? $r('app.string.dash_save_conflict') :
        $r('app.string.profile_unsaved_message'),
      alignment: DialogAlignment.Bottom, systemMaterial: this.appStyle.sheetMaterial(), autoCancel: true,
      sheets: [
        { title: $r('app.string.dash_retry_save'), action: (): void => { choice = 'retry'; } },
        { title: $r('app.string.profile_discard'), action: (): void => { choice = 'discard'; } }
      ],
      confirm: { value: $r('app.string.action_cancel'), defaultFocus: true, action: (): void => {} },
      onWillDismiss: (action: DismissDialogAction): void => action.dismiss(),
      onDidDisappear: (): void => {
        this.recoveryShown = false;
        if (!this.appeared || !this.visible || this.settings.saving) { return; }
        if (choice === 'discard') {
          this.settings.discardDraft();
          this.editing = nextEditing;
        } else if (choice === 'retry') {
          this.retrySave().then((saved: boolean): void => {
            if (saved && this.appeared && this.visible) { this.editing = nextEditing; }
          });
        }
      }
    });
  }

  private menus(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        label: this.settings.saving ? $r('app.string.dash_saving') : !this.settings.ready &&
          this.settings.failure !== '' ? $r('app.string.dash_retry') :
          this.editing ? $r('app.string.dash_done') : $r('app.string.dash_edit_cards'),
        icon: this.editing ? $r('sys.symbol.checkmark') : $r('sys.symbol.pencil_line'),
        isEnabled: !this.settings.saving && !this.loadingSettings &&
          (this.settings.ready || this.settings.failure !== ''),
        action: (): void => { this.editCards(); }
      }
    }];
  }

  private async saveCards(cards: string[]): Promise<boolean> {
    if (!this.appeared || !this.visible || !this.editing || this.settings.saving || this.savingCards ||
      this.settings.hasDraft) {
      return false;
    }
    this.savingCards = true;
    try {
      await this.settings.commit({ cards: cards }, this.settings.revision);
      return true;
    } catch (e) {
      return false;
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

  private async retrySave(): Promise<boolean> {
    if (!this.appeared || !this.visible || this.settings.saving || this.savingCards || !this.settings.hasDraft) {
      return false;
    }
    this.savingCards = true;
    try {
      await this.settings.retryDraft();
      return true;
    } catch (e) {
      return false;
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
      .backgroundColor(this.appStyle.palette.brand)
      .accessibilityText(uiResourceText(this.getUIContext(), dashboardCardTitle(id)))
      .onClick((): void => { this.saveCards([...this.settings.cards, id]); })
      Stack() {
        AppGlyph({ name: dashboardCardGlyph(id), iconSize: 20, iconColor: $r('sys.color.font_secondary') })
      }
      .width(40)
      .height(40)
      .borderRadius(14)
      .backgroundColor(this.appStyle.palette.cardBackground)
      Column() {
        Text(dashboardCardTitle(id))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .lineHeight(20)
          .fontWeight(600)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (dashboardCardDescription(id) !== '') {
          Text(dashboardCardDescription(id))
            .fontFamily(this.appStyle.fontFamily)
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
    .backgroundColor(this.appStyle.palette.dashAddableBackground)
    .enabled(!this.settings.saving && !this.settings.hasDraft)
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
          .enabled(!this.settings.saving && !this.settings.hasDraft)
          .accessibilityText($r('app.string.dash_remove'))
          .onClick((): void => {
            this.saveCards(this.settings.cards.filter((card: string): boolean => card !== id));
          })
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : this.controlTransition)
        }
      }
      .width('100%')
      .draggable(this.editing && !this.settings.saving && !this.settings.hasDraft)
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
      DashboardMode({ visible: this.visible, interactive: !this.editing,
        motionEnabled: this.visible && !this.reduceMotion })
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
      DashboardConnections({ visible: this.visible, interactive: !this.editing,
        onOpen: (target: DiagnosticFeedTarget): void => { this.onOpenDiagnostic(target); } })
    } else if (id === 'lan') {
      DashboardLan({ visible: this.visible, interactive: !this.editing, routeRevision: this.routeRevision })
    } else if (id === 'memory') {
      DashboardMemory({ visible: this.visible, interactive: !this.editing })
    }
  }

  @Builder
  DashboardContent() {
      if (this.settings.ready) {
        Column({ space: 8 }) {
          ForEach(this.displayedCards, (id: string): void => {
            this.EditableCard(id)
          }, (id: string): string => id)
          if (this.editing && this.availableCards().length > 0) {
            Column({ space: 8 }) {
              Text($r('app.string.dash_add_cards'))
                .fontFamily(this.appStyle.fontFamily)
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

  @Builder
  LiveStatusAction() {
    if (!this.editing) {
      DashboardLiveStatus({ visible: this.visible, onOpenResources: (): void => this.onOpenResources() })
    }
  }

  build() {
    TabPage({ title: this.editing ? $r('app.string.dash_edit_cards') : $r('app.string.tab_home'),
      topInset: this.topInset, scroller: this.scroller, content: (): void => this.DashboardContent(),
      menus: this.menus(), headerAction: (): void => this.LiveStatusAction(),
      onScrollDirection: (down: boolean): void => { this.onScrollDirection(down); } })
  }
}
