import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { readProfileQrPhoto, scanProfileQr } from '../../client/ProfileQrScanner';
import { EmptyState } from '../../components/EmptyState';
import { ListSource } from '../../components/ListSource';
import { TabPage } from '../../components/TabPage';
import { PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { confirmCustomDismiss, CustomProfileDraft } from './CustomProfileDraft';
import { CustomProfileEditor } from './CustomProfileEditor';
import { ProfileCard } from './ProfileCard';
import { ProfileDetails } from './ProfileDetails';
import { ProfileDraft } from './ProfileDraft';
import { confirmProfileEditorDismiss, ProfileEditor } from './ProfileEditor';
import { describeError } from './ProfileErrors';
import { ProfileImportSheet } from './ProfileImportSheet';
import { ProfileBatchResult, ProfileItem, ProfileStore } from './Profiles';
import { ProfileResults } from './ProfileResults';
import { ProfileSortSheet } from './ProfileSortSheet';

type ProfileAddChoice = 'file' | 'link' | 'custom' | 'camera' | 'photo';

@ComponentV2
export struct ProfilesPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require scroller: Scroller;
  @Event onExtension: (profile: string) => void = (_profile: string): void => {};
  @Event onScrollDirection: (down: boolean) => void = (): void => {};
  @Param topInset: number = 0;
  @Param pickerMode: boolean = false;
  @Param visible: boolean = true;
  @Local detailShown: boolean = false;
  @Local detailItem: ProfileItem | undefined = undefined;
  @Local addShown: boolean = false;
  @Local addMenuShown: boolean = false;
  @Local adding: boolean = false;
  @Local private scanningQr: boolean = false;
  @Local private addSource: string = '';
  @Local editShown: boolean = false;
  @Local draft: ProfileDraft | undefined = undefined;
  @Local customDraft: CustomProfileDraft | undefined = undefined;
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
  private pendingResult: boolean = false;
  private pendingResultError: string = '';
  private addChoice: ProfileAddChoice | undefined = undefined;
  private pendingQr: string = '';
  private pendingQrError: string = '';
  private mounted: boolean = false;

  private clockVisible(visible: boolean): void {
    this.clockInView = visible;
    if (this.clockTimer !== -1) { clearInterval(this.clockTimer); this.clockTimer = -1; }
    if (visible && this.visible) {
      this.currentTime = Date.now();
      this.clockTimer = setInterval((): void => { this.currentTime = Date.now(); }, 60000);
      this.showQrResult();
    }
    this.consumeApplyError();
  }

  aboutToDisappear(): void { this.mounted = false; this.clockVisible(false); }

  @Monitor('visible')
  onVisibilityChange(): void { this.clockVisible(this.clockInView); }

  aboutToAppear(): void {
    this.mounted = true;
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
    if (this.consumeBatchResult()) { return; }
    if (this.draft?.saving === true || (this.editShown && this.draft?.error === this.store.applyError)) {
      this.reportedApplyError = this.store.applyError;
      return;
    }
    if (this.activeActions === 0) { this.reportResult(undefined); }
  }

  private consumeBatchResult(): boolean {
    const result = this.result;
    if (!this.pendingResult || result === undefined) { return false; }
    if (!this.visible || !this.clockInView) { return true; }
    this.pendingResult = false;
    this.reportedApplyError = this.pendingResultError;
    if (result.failures.length === 1) {
      const failure = result.failures[0];
      this.toast($r('app.string.profile_update_failed', failure.name, describeError(failure.error)));
    } else {
      this.resultShown = true;
    }
    return true;
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
  private openAdd(source: string = ''): void {
    this.addSource = source;
    this.addShown = true;
  }
  private openEdit(item: ProfileItem): void {
    if (item.type === 'custom') { this.customDraft = new CustomProfileDraft(item); }
    else { this.draft = new ProfileDraft(item); }
    this.editShown = true;
  }

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
      isEnabled: this.store.loaded && this.store.loadError === '' && !this.scanningQr,
      action: (): void => this.showAddMenu() } });
    return menus;
  }

  private showAddMenu(): void {
    this.addChoice = undefined;
    this.addMenuShown = true;
  }

  private finishAddMenu(): void {
    const choice = this.addChoice;
    this.addChoice = undefined;
    if (!this.visible) { return; }
    if (choice === 'file') { this.importLocal(); }
    else if (choice === 'link') { this.openAdd(); }
    else if (choice === 'custom') { this.customDraft = new CustomProfileDraft(); this.editShown = true; }
    else if (choice === 'camera' || choice === 'photo') { this.importQr(choice === 'camera'); }
  }

  private async importQr(camera: boolean): Promise<void> {
    if (this.scanningQr) { return; }
    this.scanningQr = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const source = camera ? await scanProfileQr(context) : await readProfileQrPhoto();
      if (this.mounted) { this.pendingQr = source ?? ''; }
    } catch (error) {
      if (this.mounted) { this.pendingQrError = errorString(error as Object); }
    } finally {
      this.scanningQr = false;
      this.showQrResult();
    }
  }

  private showQrResult(): void {
    if (!this.mounted || !this.visible || !this.clockInView) { return; }
    const source = this.pendingQr;
    const failure = this.pendingQrError;
    this.pendingQr = '';
    this.pendingQrError = '';
    if (source !== '') { this.openAdd(source); }
    if (failure !== '') { this.toast(describeError(failure)); }
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
      this.pendingResult = result.failures.length > 0;
      this.pendingResultError = this.store.applyError;
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
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20).fontWeight(600).fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($r('app.string.delete_confirm_message'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15).fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Button({ type: ButtonType.Normal, role: ButtonRole.ERROR, stateEffect: true }) {
          Row({ space: 8 }) {
            if (this.removing) {
              LoadingProgress().width(20).height(20).color($r('app.color.status_error'))
            }
            Text($r('app.string.action_delete')).fontFamily(this.appStyle.fontFamily).fontSize(17).fontColor($r('app.color.status_error'))
          }
          .justifyContent(FlexAlign.Center)
        }
        .buttonStyle(ButtonStyleMode.NORMAL)
        .width('100%').height(48).borderRadius(24)
        .enabled(!this.removing && this.store.canRemove(this.removeItem.id))
        .onClick((): void => { this.remove(); })
        Button($r('app.string.action_cancel'))
          .fontFamily(this.appStyle.fontFamily)
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
        ListItem() { LoadingProgress().width(32).height(32).color(this.appStyle.palette.brand) }
      } else if (this.store.loadError !== '') {
        ListItem() {
          Column({ space: 12 }) {
            Text($r('app.string.profile_load_error', describeError(this.store.loadError)))
              .fontFamily(this.appStyle.fontFamily)
              .fontColor($r('app.color.status_error'))
            Button($r('app.string.action_update')).fontFamily(this.appStyle.fontFamily).onClick((): void => this.store.retryLoad())
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
              applying: this.store.pending === item.id, running: this.store.coreReady && this.store.running === item.id,
              removable: this.store.canRemove(item.id), onSelect: (): void => { this.select(item); },
              onEdit: (): void => this.openEdit(item), onRemove: (): void => this.confirmRemove(item),
              onCopy: (): void => { this.copyLink(item); }, onExport: (): void => { this.export(item); },
              onUpdate: (): void => { this.update(item); },
              extensionAvailable: !this.pickerMode && item.type !== 'custom',
              onExtension: (): void => this.onExtension(item.id),
              onDetails: (): void => { this.detailItem = item; this.detailShown = true; } })
          }
        }, (item: ProfileItem): string => item.id)
      }
    }

  @Builder
  EditSheet() {
    if (this.customDraft !== undefined) {
      CustomProfileEditor({ store: this.store, draft: this.customDraft,
        onClose: (): void => { this.editShown = false; } })
    } else if (this.draft !== undefined) {
      ProfileEditor({ store: this.store, draft: this.draft, visible: this.visible && this.editShown, onSaved: (): void => {
        if (this.draft !== undefined) { this.draft.saving = false; }
        this.editShown = false;
      }, onClose: (): void => confirmProfileEditorDismiss(this.getUIContext(), this.draft,
        (): void => { this.editShown = false; }) })
    }
  }

  @Builder
  AddOption(label: Resource, icon: Resource, choice: ProfileAddChoice) {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL, stateEffect: true }) {
      Row({ space: 12 }) {
        SymbolGlyph(icon).fontSize(24).fontColor([$r('sys.color.font_primary')])
        Text(label).fontFamily(this.appStyle.fontFamily).fontSize(17).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%').height(56).padding({ left: 16, right: 16 })
    .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(24)
    .onClick((): void => { this.addChoice = choice; this.addMenuShown = false; })
  }

  @Builder
  AddMenu() {
    Column({ space: 8 }) {
      this.AddOption($r('app.string.profile_import_file'), $r('sys.symbol.doc_text'), 'file')
      this.AddOption($r('app.string.profile_import_link'), $r('sys.symbol.link'), 'link')
      this.AddOption($r('app.string.profile_qr_scan'), $r('sys.symbol.qrcode'), 'camera')
      this.AddOption($r('app.string.profile_qr_photo'), $r('sys.symbol.picture'), 'photo')
      this.AddOption($r('app.string.custom_create'), $r('sys.symbol.plus'), 'custom')
    }
    .width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
  }

  @Builder
  AddSheet() {
    ProfileImportSheet({ store: this.store, initialSource: this.addSource, onDone: (): void => {
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
              height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
              onWillDismiss: (action: DismissSheetAction): void => {
                if (this.customDraft !== undefined) {
                  confirmCustomDismiss(this.getUIContext(), this.customDraft, (): void => action.dismiss());
                } else { confirmProfileEditorDismiss(this.getUIContext(), this.draft, (): void => action.dismiss()); }
              },
              onDisappear: (): void => { this.draft = undefined; this.customDraft = undefined; } })
          }
          .width('100%').height('100%')
          .bindSheet($$this.detailShown, this.DetailSheet(), { title: { title: $r('app.string.profile_details_title') },
            height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
        }
        .width('100%').height('100%')
        .bindSheet($$this.sortShown, this.SortSheet(), {
          height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false })
      }
      .width('100%').height('100%')
      .bindSheet($$this.resultShown, this.ResultSheet(), { title: { title: $r('app.string.action_update_all') },
        height: SheetSize.FIT_CONTENT, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
    }
    .width('100%').height('100%')
    .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
      this.profileColumns = Math.max(1, Math.min(3, Math.floor((Number(next.width ?? 0) - 32 + 8) / (300 + 8))));
    })
    .onVisibleAreaChange([0.0, 1.0], (visible: boolean, ratio: number): void => this.clockVisible(visible && ratio > 0))
    .bindSheet($$this.addShown, this.AddSheet(), {
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
      onDisappear: (): void => { this.addSource = ''; },
      onWillDismiss: (action: DismissSheetAction): void => { if (!this.adding) { action.dismiss(); } } })
  }

  build() {
    Column() {
      Column() { this.PageSheets() }
      .width('100%').height('100%')
      .bindSheet($$this.addMenuShown, this.AddMenu(), {
        title: { title: $r('app.string.action_add') },
        height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
        systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
        onDisappear: (): void => this.finishAddMenu()
      })
    }
    .width('100%').height('100%')
    .bindSheet($$this.removeShown, this.RemoveSheet(), {
      height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
      systemMaterial: this.appStyle.sheetMaterial(), showClose: false, enableOutsideInteractive: false,
      onWillDismiss: (action: DismissSheetAction): void => { if (!this.removing) { action.dismiss(); } },
      onDisappear: (): void => { if (!this.removeShown) { this.removeItem = undefined; } }
    })
  }
}
