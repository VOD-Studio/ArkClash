import { AppearanceState, appAppearance } from '../components/AppearanceState';
import { connection, Connection } from '../client/Connection';
import { DiagnosticFeedTarget } from '../client/Diagnostics';
import { HomePage } from '../features/home/HomePage';
import { ProfileDetailsSheet } from '../features/profiles/ProfileDetailsSheet';
import { ProfileImportSheet } from '../features/profiles/ProfileImportSheet';
import { ProfileItem, ProfileStore } from '../features/profiles/Profiles';
import { SummaryGroup } from '../shared/profiles/Summary';

@ComponentV2
export struct DashboardTab {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require scroller: Scroller;
  @Param topInset: number = 0;
  @Param visible: boolean = false;
  @Param closeEditSignal: number = 0;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Event onEditingChanged: (editing: boolean) => void = () => {};
  @Event onSwitchProfile: () => void = () => {};
  @Event onOpenProfiles: () => void = () => {};
  @Event onOpenProxies: () => void = () => {};
  @Event onOpenResources: () => void = () => {};
  @Event onOpenDiagnostic: (target: DiagnosticFeedTarget) => void = (_target: DiagnosticFeedTarget): void => {};
  @Event onRuntimePreview: (profile: string, name: string) => void = (_profile: string, _name: string): void => {};
  @Local conn: Connection = connection;
  @Local detailShown: boolean = false;
  @Local detailItem: ProfileItem | undefined = undefined;
  @Local addShown: boolean = false;
  @Local adding: boolean = false;

  @Computed
  get activeProfile(): ProfileItem | undefined {
    return this.store.active();
  }

  @Computed
  get summaryGroupIcons(): Record<string, string> {
    const icons: Record<string, string> = {};
    for (const group of this.store.summary?.groups ?? []) {
      if (group.icon !== undefined && group.icon !== '') { icons[group.name] = group.icon; }
    }
    return icons;
  }

  @Builder
  Details() {
    if (this.detailItem !== undefined) {
      ProfileDetailsSheet({ store: this.store, item: this.detailItem, visible: this.visible && this.detailShown,
        runtimePreviewAvailable: true,
        onRuntimePreview: (): void => {
          const item = this.detailItem;
          this.detailShown = false;
          if (item !== undefined) { this.onRuntimePreview(item.id, item.name); }
        } })
    }
  }

  @Builder
  Import() {
    ProfileImportSheet({ store: this.store,
      onDone: (): void => { this.adding = false; this.addShown = false; },
      onBusy: (busy: boolean): void => { this.adding = busy; },
      onClose: (): void => { if (!this.adding) { this.addShown = false; } } })
  }

  build() {
    Column() {
      Column() {
        HomePage({
          scroller: this.scroller, topInset: this.topInset, visible: this.visible,
          closeEditSignal: this.closeEditSignal,
          onScrollDirection: (down: boolean): void => this.onScrollDirection(down),
          onEditingChanged: (editing: boolean): void => this.onEditingChanged(editing),
          profileReady: this.store.ready,
          canSwitchProfile: this.store.items.length > 1,
          onSwitchProfile: (): void => this.onSwitchProfile(),
          profileId: this.activeProfile?.id ?? '',
          profileProxyCount: this.store.summary?.proxies ?? -1,
          profileSource: this.activeProfile?.isSubscription === true ? 'url' : 'local',
          routeRevision: this.conn.routeRevision,
          onOpenProfile: (): void => {
            this.detailItem = this.activeProfile;
            this.detailShown = this.detailItem !== undefined;
          },
          profileName: this.activeProfile?.name ?? '',
          profileUpdatedAt: this.activeProfile?.state.updatedAt ?? 0,
          profileUpdating: this.activeProfile?.updating ?? false,
          profileUpdatable: this.activeProfile?.isSubscription ?? false,
          usedBytes: (this.activeProfile?.state.usage?.upload ?? 0) +
            (this.activeProfile?.state.usage?.download ?? 0),
          totalBytes: this.activeProfile?.state.usage?.total ?? 0,
          expireAt: this.activeProfile?.state.usage?.expire ?? 0,
          summaryGroups: this.store.summary?.groups.map((group: SummaryGroup): string => group.name) ?? [],
          summaryGroupIcons: this.summaryGroupIcons,
          onAddProfile: (): void => { this.addShown = true; },
          onOpenProfiles: (): void => this.onOpenProfiles(),
          onUpdateProfile: (): void => {
            const active = this.activeProfile;
            if (active !== undefined) { this.store.update(active.id); }
          },
          onOpenProxies: (): void => this.onOpenProxies(),
          onOpenResources: (): void => this.onOpenResources(),
          onOpenDiagnostic: (target: DiagnosticFeedTarget): void => this.onOpenDiagnostic(target)
        })
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.detailShown, this.Details, {
        title: { title: $r('app.string.profile_details_title') },
        detents: [SheetSize.MEDIUM, SheetSize.LARGE], systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
        onDisappear: (): void => { this.detailItem = undefined; }
      })
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.addShown, this.Import, {
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
      onWillDismiss: (action: DismissSheetAction): void => { if (!this.adding) { action.dismiss(); } }
    })
  }
}
