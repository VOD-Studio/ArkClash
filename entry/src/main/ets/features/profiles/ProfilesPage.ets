import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { EmptyState } from '../../components/EmptyState';
import { ListSource } from '../../components/ListSource';
import { TabPage } from '../../components/TabPage';
import { PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { ProfileCard } from './ProfileCard';
import { ProfileDetails } from './ProfileDetails';
import { ProfileDraft } from './ProfileDraft';
import { confirmProfileEditorDismiss, ProfileEditor } from './ProfileEditor';
import { describeError } from './ProfileErrors';
import { ProfileImportSheet } from './ProfileImportSheet';
import { ProfileBatchResult, ProfileItem, ProfileStore } from './Profiles';
import { ProfileResults } from './ProfileResults';
import { ProfileSortSheet } from './ProfileSortSheet';

@ComponentV2
export struct ProfilesPage {
  @Param @Require store: ProfileStore;
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = (): void => {};
  @Param topInset: number = 0;
  @Param pickerMode: boolean = false;
  @Param visible: boolean = true;
  @Local detailShown: boolean = false;
  @Local detailItem: ProfileItem | undefined = undefined;
  @Local addShown: boolean = false;
  @Local adding: boolean = false;
  @Local editShown: boolean = false;
  @Local draft: ProfileDraft | undefined = undefined;
  @Local sortShown: boolean = false;
  @Local resultShown: boolean = false;
  @Local result: ProfileBatchResult | undefined = undefined;
  @Local removeShown: boolean = false;
  @Local removeItem: ProfileItem | undefined = undefined;
  @Local removing: boolean = false;
  @Local profileColumns: number = 1;
  @Local currentTime: number = Date.now();
  private rows: ListSource<ProfileItem> = new ListSource<ProfileItem>();
  private clockTimer: number = -1;
  private clockInView: boolean = false;
  private activeActions: number = 0;
  private reportedApplyError: string = '';

  private clockVisible(visible: boolean): void {
    this.clockInView = visible;
    if (this.clockTimer !== -1) { clearInterval(this.clockTimer); this.clockTimer = -1; }
    if (visible && this.visible) {
      this.currentTime = Date.now();
      this.clockTimer = setInterval((): void => { this.currentTime = Date.now(); }, 60000);
    }
    this.consumeApplyError();
  }

  aboutToDisappear(): void { this.clockVisible(false); }

  @Monitor('visible')
  onVisibilityChange(): void { this.clockVisible(this.clockInView); }

  aboutToAppear(): void {
    this.rows.replace(this.store.items);
  }

  @Monitor('store.items')
  onItemsChanged(): void { this.rows.replace(this.store.items); }

  @Monitor('store.applyError')
  onApplyErrorChanged(): void {
    if (this.store.applyError === '') { this.reportedApplyError = ''; }
    this.consumeApplyError();
  }

  private consumeApplyError(): void {
    if (this.activeActions === 0) { this.reportResult(undefined); }
  }

  private reportResult(failure: string | undefined, success?: ResourceStr, errorMessage?: ResourceStr): void {
    if (!this.visible || !this.clockInView) { return; }
    const applyError = this.store.applyError;
    const error = failure ?? (applyError !== '' && applyError !== this.reportedApplyError ? applyError : undefined);
    if (error !== undefined) {
      // 手动结果与状态监听共用消费记录，避免同次失败弹出两次提示。
      this.reportedApplyError = applyError;
      this.toast(failure !== undefined && errorMessage !== undefined ? errorMessage : describeError(error));
    } else if (success !== undefined) {
      this.toast(success);
    }
  }

  private toast(message: ResourceStr): void {
    if (this.visible && this.clockInView) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }
  private openAdd(): void { this.addShown = true; }
  private openEdit(item: ProfileItem): void { this.draft = new ProfileDraft(item); this.editShown = true; }

  private menus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.store.items.some((item: ProfileItem): boolean => item.isSubscription)) {
      menus.push({ content: { label: $r('app.string.action_update_all'), icon: $r('sys.symbol.arrow_clockwise'),
        isEnabled: !this.store.updatingAll, action: (): void => { this.updateAll(); } } });
    }
    if (this.store.items.length > 0) {
      menus.push({ content: { label: $r('app.string.profile_sort'), icon: $r('sys.symbol.sort'),
        action: (): void => { this.sortShown = true; } } });
    }
    menus.push({ content: { label: $r('app.string.action_add'), icon: $r('sys.symbol.plus'),
      isEnabled: this.store.loaded && this.store.loadError === '', action: (): void => this.showAddMenu() } });
    return menus;
  }

  private showAddMenu(): void {
    this.getUIContext().getPromptAction().showActionMenu({ buttons: [
      { text: $r('app.string.profile_import_file'), color: $r('sys.color.font_primary') },
      { text: $r('app.string.subscription_link'), color: $r('sys.color.font_primary') }
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) { this.importLocal(); }
      else if (result.index === 1) { this.openAdd(); }
    }).catch((): void => {});
  }

  private async importLocal(): Promise<void> {
    this.activeActions++;
    try {
      const failure = await this.store.importLocal();
      this.reportResult(failure, undefined,
        failure === undefined ? undefined : $r('app.string.import_failed', describeError(failure)));
    } finally { this.activeActions--; this.consumeApplyError(); }
  }
  private async select(item: ProfileItem): Promise<void> {
    this.activeActions++;
    try {
      const failure = await this.store.select(item.id);
      this.reportResult(failure, undefined,
        failure === undefined ? undefined : $r('app.string.profile_switch_failed', describeError(failure)));
    } finally { this.activeActions--; this.consumeApplyError(); }
  }
  private async update(item: ProfileItem): Promise<void> {
    this.activeActions++;
    try {
      const failure = await this.store.update(item.id);
      this.reportResult(failure, $r('app.string.profile_updated_toast'),
        failure === undefined ? undefined : $r('app.string.download_failed', describeError(failure)));
    } finally { this.activeActions--; this.consumeApplyError(); }
  }
  private async updateAll(): Promise<void> {
    this.activeActions++;
    try {
      const result: ProfileBatchResult = await this.store.updateAll();
      this.result = result;
      if (result.failures.length === 1) {
        const failure = result.failures[0];
        this.reportResult(failure.error, undefined,
          $r('app.string.profile_update_failed', failure.name, describeError(failure.error)));
      } else if (result.failures.length > 1) {
        this.reportedApplyError = this.store.applyError;
        if (this.visible && this.clockInView) { this.resultShown = true; }
      }
    } finally { this.activeActions--; this.consumeApplyError(); }
  }
  private async export(item: ProfileItem): Promise<void> {
    const failure = await this.store.export(item.id);
    if (failure !== undefined) { this.toast(describeError(failure)); }
  }
  private async copyLink(item: ProfileItem): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.url);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast($r('app.string.copied'));
    } catch (e) { this.toast(describeError('io')); }
  }
  private confirmRemove(item: ProfileItem): void {
    if (this.removing) { return; }
    this.removeItem = item;
    this.removeShown = true;
  }

  private async remove(): Promise<void> {
    const item = this.removeItem;
    if (item === undefined || this.removing) { return; }
    this.removing = true;
    this.activeActions++;
    try {
      const failure = await this.store.remove(item.id);
      this.reportResult(failure);
      this.removeShown = false;
    } finally {
      this.removing = false;
      this.activeActions--;
      this.consumeApplyError();
    }
  }

  @Builder
  RemoveSheet() {
    if (this.removeItem !== undefined) {
      Column({ space: 16 }) {
        Text($r('app.string.delete_confirm_title', this.removeItem.name))
          .fontSize(20).fontWeight(600).fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($r('app.string.delete_confirm_message'))
          .fontSize(15).fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Button({ type: ButtonType.Normal, role: ButtonRole.ERROR, stateEffect: true }) {
          Row({ space: 8 }) {
            if (this.removing) {
              LoadingProgress().width(20).height(20).color($r('app.color.status_error'))
            }
            Text($r('app.string.action_delete')).fontSize(17).fontColor($r('app.color.status_error'))
          }
          .justifyContent(FlexAlign.Center)
        }
        .buttonStyle(ButtonStyleMode.NORMAL)
        .width('100%').height(48).borderRadius(24)
        .enabled(!this.removing && this.store.canRemove(this.removeItem.id))
        .onClick((): void => { this.remove(); })
        Button($r('app.string.action_cancel'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .width('100%').height(48)
          .enabled(!this.removing)
          .onClick((): void => { this.removeShown = false; })
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 24 })
    }
  }

  @Builder
  Content() {
    if (this.pickerMode) {
      List({ scroller: this.scroller, space: 8 }) {
        this.ProfileList()
      }
      .width('100%').height('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      .contentStartOffset(8).contentEndOffset(24)
      .lanes(this.profileColumns, 8)
      .cachedCount(2)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    } else {
      TabPage({ title: $r('app.string.tab_profiles'), topInset: this.topInset, scroller: this.scroller,
        listMode: true, listSpacing: 8, listLanes: this.profileColumns, listGutter: 8,
        menus: this.menus(), onScrollDirection: (down: boolean): void => this.onScrollDirection(down),
        content: (): void => this.ProfileList() })
    }
  }

  @Builder
  ProfileList() {
      if (!this.store.loaded) {
        ListItem() { LoadingProgress().width(32).height(32).color($r('app.color.brand')) }
      } else if (this.store.loadError !== '') {
        ListItem() {
          Column({ space: 12 }) {
            Text($r('app.string.profile_load_error', describeError(this.store.loadError)))
              .fontColor($r('app.color.status_error'))
            Button($r('app.string.action_update')).onClick((): void => this.store.retryLoad())
          }.width('100%').padding(16)
        }
      } else if (this.store.items.length === 0) {
        ListItem() {
          Column() {
            EmptyState({ icon: $r('sys.symbol.doc_text'), title: $r('app.string.home_no_profile'),
              hint: $r('app.string.home_no_profile_hint'), actionLabel: $r('app.string.action_add'),
              onAction: (): void => this.showAddMenu() })
          }.width('100%')
        }
      } else {
        LazyForEach(this.rows, (item: ProfileItem) => {
          ListItem() {
            ProfileCard({ item: item, selected: this.store.selectedId() === item.id, currentTime: this.currentTime,
              applying: this.store.pending === item.id, running: this.store.connected && this.store.running === item.id,
              removable: this.store.canRemove(item.id), onSelect: (): void => { this.select(item); },
              onEdit: (): void => this.openEdit(item), onRemove: (): void => this.confirmRemove(item),
              onCopy: (): void => { this.copyLink(item); }, onExport: (): void => { this.export(item); },
              onUpdate: (): void => { this.update(item); },
              onDetails: (): void => { this.detailItem = item; this.detailShown = true; } })
          }
        }, (item: ProfileItem): string => item.id)
      }
    }

  @Builder
  EditSheet() {
    if (this.draft !== undefined) {
      ProfileEditor({ store: this.store, draft: this.draft, onSaved: (): void => {
        if (this.draft !== undefined) { this.draft.saving = false; }
        this.editShown = false;
      }, onClose: (): void => confirmProfileEditorDismiss(this.getUIContext(), this.draft,
        (): void => { this.editShown = false; }) })
    }
  }
  @Builder
  AddSheet() {
    ProfileImportSheet({ store: this.store, onDone: (): void => {
      this.adding = false; this.addShown = false;
    }, onBusy: (busy: boolean): void => { this.adding = busy; },
      onClose: (): void => { if (!this.adding) { this.addShown = false; } } })
  }
  @Builder
  SortSheet() {
    ProfileSortSheet({ store: this.store, onSaved: (): void => { this.sortShown = false; },
      onClose: (): void => { this.sortShown = false; } })
  }
  @Builder
  ResultSheet() {
    Column() { if (this.result !== undefined) { ProfileResults({ result: this.result }) } }
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  @Builder
  DetailSheet() {
    if (this.detailItem !== undefined) {
      ProfileDetails({ store: this.store, item: this.detailItem, onEdit: (): void => {
        const item = this.detailItem;
        this.detailShown = false;
        if (item !== undefined) { this.openEdit(item); }
      } })
    }
  }

  @Builder
  PageSheets() {
    Column() {
      Column() {
        Column() {
          Column() {
          Column() { this.Content() }
            .width('100%').height('100%')
            .bindSheet($$this.editShown, this.EditSheet(), {
              height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false,
              onWillDismiss: (action: DismissSheetAction): void =>
                confirmProfileEditorDismiss(this.getUIContext(), this.draft, (): void => action.dismiss()),
              onDisappear: (): void => { this.draft = undefined; } })
          }
          .width('100%').height('100%')
          .bindSheet($$this.detailShown, this.DetailSheet(), { title: { title: $r('app.string.profile_details_title') },
            height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: true })
        }
        .width('100%').height('100%')
        .bindSheet($$this.sortShown, this.SortSheet(), {
          height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false })
      }
      .width('100%').height('100%')
      .bindSheet($$this.resultShown, this.ResultSheet(), { title: { title: $r('app.string.action_update_all') },
        height: SheetSize.FIT_CONTENT, systemMaterial: sheetMaterial(), showClose: true })
    }
    .width('100%').height('100%')
    .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
      this.profileColumns = Math.max(1, Math.min(3, Math.floor((Number(next.width ?? 0) - 32 + 8) / (300 + 8))));
    })
    .onVisibleAreaChange([0.0, 1.0], (visible: boolean, ratio: number): void => this.clockVisible(visible && ratio > 0))
    .bindSheet($$this.addShown, this.AddSheet(), {
      height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false,
      onWillDismiss: (action: DismissSheetAction): void => { if (!this.adding) { action.dismiss(); } } })
  }

  build() {
    Column() { this.PageSheets() }
    .width('100%').height('100%')
    .bindSheet($$this.removeShown, this.RemoveSheet(), {
      height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
      systemMaterial: sheetMaterial(), showClose: false, enableOutsideInteractive: false,
      onWillDismiss: (action: DismissSheetAction): void => { if (!this.removing) { action.dismiss(); } },
      onDisappear: (): void => { if (!this.removeShown) { this.removeItem = undefined; } }
    })
  }
}
