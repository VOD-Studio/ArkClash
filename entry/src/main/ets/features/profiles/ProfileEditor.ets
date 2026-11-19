import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { UIContext } from '@kit.ArkUI';
import { formatDateTime } from '../../components/Format';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';
import { ProfileDraft } from './ProfileDraft';
import { ProfileFilterPicker } from './ProfileFilterPicker';
import { ProfileIconPicker } from './ProfileIconPicker';
import { ProfileEdit, ProfileStore } from './Profiles';
import { ProfileSheetHeader } from './ProfileSheetHeader';

export function confirmProfileEditorDismiss(context: UIContext, draft: ProfileDraft | undefined,
  dismiss: () => void): void {
  if (draft === undefined) { dismiss(); return; }
  if (draft.saving) { return; }
  if (!draft.dirty()) { dismiss(); return; }
  let choice: 'save' | 'discard' | undefined = undefined;
  context.showActionSheet({
    title: $r('app.string.profile_unsaved_title'), message: $r('app.string.profile_unsaved_message'),
    alignment: DialogAlignment.Bottom, systemMaterial: appAppearance.sheetMaterial(), autoCancel: true,
    sheets: [
      { title: $r('app.string.action_save'), action: (): void => { choice = 'save'; } },
      { title: $r('app.string.profile_discard'), action: (): void => { choice = 'discard'; } }
    ],
    confirm: { value: $r('app.string.profile_keep_editing'), defaultFocus: true, action: (): void => {} },
    onWillDismiss: (action: DismissDialogAction): void => action.dismiss(),
    onDidDisappear: (): void => {
      if (choice === 'discard') { dismiss(); }
      if (choice === 'save') {
        draft.save?.().then((saved: boolean): void => { if (saved) { dismiss(); } });
      }
    }
  });
}

@ComponentV2
export struct ProfileEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require draft: ProfileDraft;
  @Param @Require visible: boolean;
  @Event onSaved: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local sourceShown: boolean = false;
  @Local private sourcePanel: 'text' | 'filter' | 'icon' = 'text';
  @Local sourceText: string = '';
  @Local sourceOriginal: string = '';
  @Local loadingSource: boolean = false;
  @Local validating: boolean = false;
  private cancelAutoUpdateChoice: (() => void) | undefined = undefined;
  private appeared: boolean = false;
  private pendingFailure: string | undefined = undefined;

  aboutToAppear(): void {
    this.appeared = true;
    this.draft.save = (): Promise<boolean> => this.save();
    this.consumeFailure();
  }
  aboutToDisappear(): void {
    this.appeared = false;
    this.pendingFailure = undefined;
    this.draft.save = undefined;
    this.cancelAutoUpdateChoice?.();
  }

  private toast(message: ResourceStr): void {
    if (this.appeared && this.visible) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private reportFailure(failure: string): void {
    this.draft.error = failure;
    if (!this.appeared) { return; }
    this.pendingFailure = failure;
    this.consumeFailure();
  }

  @Monitor('visible')
  consumeFailure(): void {
    const failure = this.pendingFailure;
    if (!this.appeared || !this.visible || failure === undefined) { return; }
    this.toast(describeError(failure));
    this.pendingFailure = undefined;
  }

  private async openSource(): Promise<void> {
    if (this.loadingSource) { return; }
    this.loadingSource = true;
    this.draft.error = '';
    try {
      const text = this.draft.content ?? await this.store.source(this.draft.id);
      if (!this.appeared) { return; }
      this.sourceText = text;
      this.sourceOriginal = this.sourceText;
      this.sourcePanel = 'text';
      this.sourceShown = true;
    } catch (e) { this.reportFailure(errorString(e as Object)); }
    finally { this.loadingSource = false; }
  }

  private async pickSource(): Promise<void> {
    if (this.loadingSource) { return; }
    this.loadingSource = true;
    try {
      const text = await this.store.pickSource();
      if (text !== undefined) {
        const original = this.draft.content ?? await this.store.source(this.draft.id);
        if (!this.appeared) { return; }
        this.sourceOriginal = original;
        this.sourceText = text;
        this.sourcePanel = 'text';
        this.sourceShown = true;
      }
    } catch (e) { this.reportFailure(errorString(e as Object)); }
    finally { this.loadingSource = false; }
  }

  private async saveSource(): Promise<boolean> {
    if (this.validating) { return false; }
    this.validating = true;
    try {
      const failure = await this.store.validateSource(this.sourceText);
      if (failure !== undefined) { this.reportFailure(failure); return false; }
      if (!this.appeared) { return false; }
      if (this.sourceText !== this.sourceOriginal) { this.draft.content = this.sourceText; }
      this.sourceOriginal = this.sourceText;
      this.sourceShown = false;
      return true;
    } catch (e) {
      this.reportFailure(errorString(e as Object));
      return false;
    } finally {
      this.validating = false;
    }
  }

  private closeSource(dismiss: () => void): void {
    if (this.sourcePanel !== 'text') {
      this.sourcePanel = 'text';
      return;
    }
    if (this.validating) { return; }
    if (this.sourceText === this.sourceOriginal) { dismiss(); return; }
    let choice: 'save' | 'discard' | undefined = undefined;
    this.getUIContext().showActionSheet({
      title: $r('app.string.profile_unsaved_title'), message: $r('app.string.profile_unsaved_message'),
      alignment: DialogAlignment.Bottom, systemMaterial: this.appStyle.sheetMaterial(), autoCancel: true,
      sheets: [
        { title: $r('app.string.action_save'), action: (): void => { choice = 'save'; } },
        { title: $r('app.string.profile_discard'), action: (): void => { choice = 'discard'; } }
      ],
      confirm: { value: $r('app.string.profile_keep_editing'), defaultFocus: true, action: (): void => {} },
      onWillDismiss: (action: DismissDialogAction): void => action.dismiss(),
      onDidDisappear: (): void => {
        if (choice === 'discard') { dismiss(); }
        if (choice === 'save') {
          this.saveSource().then((saved: boolean): void => { if (saved) { dismiss(); } });
        }
      }
    });
  }

  private async save(): Promise<boolean> {
    if (this.draft.saving) { return false; }
    this.draft.saving = true;
    this.draft.error = '';
    try {
      if (this.draft.content !== undefined && this.draft.subscription && this.draft.autoUpdate) {
        const disabled = await this.askDisableAutoUpdate();
        if (disabled === undefined) { return false; }
        this.draft.autoUpdate = !disabled;
      }
      const edit: ProfileEdit = { name: this.draft.name, url: this.draft.link,
        autoUpdate: this.draft.autoUpdate, intervalMinutes: Number(this.draft.interval),
        content: this.draft.content, baseContentRevision: this.draft.baseContentRevision,
        baseName: this.draft.baseName, baseUrl: this.draft.baseLink };
      const failure = await this.store.edit(this.draft.id, edit);
      if (failure !== undefined) {
        this.reportFailure(failure);
        if (failure === 'metadata_saved') { this.draft.saved(); }
        return false;
      }
      this.draft.saved();
      this.toast($r('app.string.profile_saved_toast'));
      if (this.appeared) { this.onSaved(); }
      return true;
    } catch (e) {
      this.reportFailure(errorString(e as Object));
      return false;
    } finally { this.draft.saving = false; }
  }

  private askDisableAutoUpdate(): Promise<boolean | undefined> {
    return new Promise<boolean | undefined>((resolve: (disabled: boolean | undefined) => void): void => {
      let settled = false;
      const finish = (disabled: boolean | undefined): void => {
        if (settled) { return; }
        settled = true;
        this.cancelAutoUpdateChoice = undefined;
        resolve(disabled);
      };
      this.cancelAutoUpdateChoice = (): void => finish(undefined);
      this.getUIContext().showActionSheet({
        title: $r('app.string.profile_source_title'), message: $r('app.string.profile_manual_auto_update'),
        alignment: DialogAlignment.Bottom, systemMaterial: this.appStyle.sheetMaterial(), autoCancel: true,
        sheets: [
          { title: $r('app.string.profile_keep_auto_update'), action: (): void => finish(false) },
          { title: $r('app.string.profile_disable_auto_update'), action: (): void => finish(true) }
        ],
        confirm: { value: $r('app.string.action_cancel'), defaultFocus: true,
          action: (): void => finish(undefined) },
        cancel: (): void => finish(undefined),
        onWillDismiss: (action: DismissDialogAction): void => { finish(undefined); action.dismiss(); },
        onDidDisappear: (): void => finish(undefined)
      });
    });
  }

  @Builder
  SourceActions() {
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText($r('app.string.proxy_filter_insert')).enabled(!this.validating)
    .onClick((): void => { this.sourcePanel = 'filter'; })
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      SymbolGlyph($r('sys.symbol.picture')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText($r('app.string.icon_set_choose_icon')).enabled(!this.validating)
    .onClick((): void => { this.sourcePanel = 'icon'; })
  }

  @Builder
  SourceEditor() {
    Column({ space: 12 }) {
      if (this.sourcePanel === 'filter') {
        ProfileFilterPicker({ sourceText: this.sourceText,
          onApply: (updated: string): void => {
            this.sourceText = updated;
            this.sourcePanel = 'text';
          },
          onClose: (): void => { this.sourcePanel = 'text'; } })
      } else if (this.sourcePanel === 'icon') {
        ProfileIconPicker({ sourceText: this.sourceText,
          onApply: (updated: string): void => {
            this.sourceText = updated;
            this.sourcePanel = 'text';
          },
          onClose: (): void => { this.sourcePanel = 'text'; } })
      } else {
        ProfileSheetHeader({ titleText: this.draft.name, saving: this.validating,
          actions: (): void => this.SourceActions(),
          onSave: (): void => { this.saveSource(); },
          onClose: (): void => this.closeSource((): void => { this.sourceShown = false; }) })
        TextArea({ text: this.sourceText })
          .fontFamily('monospace')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .layoutWeight(1)
          .width('100%')
          .enabled(!this.validating)
          .onChange((text: string): void => { this.sourceText = text; })
      }
    }
    .padding({ bottom: 24 })
    .height('100%')
  }

  @Builder
  FileMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit') })
        .onClick((): void => { this.openSource(); })
      MenuItem({ content: $r('app.string.profile_upload_source') })
        .onClick((): void => { this.pickSource(); })
    }
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: $r('app.string.edit_profile_title'), saving: this.draft.saving,
        canSave: !this.loadingSource, onSave: (): void => { this.save(); }, onClose: (): void => this.onClose() })
      Scroll() {
        Column({ space: 24 }) {
          Column() {
            Row({ space: 16 }) {
              Text($r('app.string.field_name')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
              TextInput({ text: this.draft.name, placeholder: $r('app.string.profile_field_required') })
                .fontFamily(this.appStyle.fontFamily)
                .maxLength(64).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                .enterKeyType(EnterKeyType.Next)
                .onChange((text: string): void => { this.draft.name = text; })
            }
            .padding({ left: 16, right: 16 }).width('100%')
            if (this.draft.subscription) {
              Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
              Row({ space: 16 }) {
                Text($r('app.string.field_link')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                TextInput({ text: this.draft.link, placeholder: $r('app.string.profile_field_required') })
                  .fontFamily(this.appStyle.fontFamily)
                  .maxLength(2048).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                  .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Next)
                  .onChange((text: string): void => { this.draft.link = text; })
              }
              .padding({ left: 16, right: 16 }).width('100%')
            }
          }
          .backgroundColor(this.appStyle.palette.cardBackground)
          .borderRadius(24).clip(true)
          if (this.draft.subscription) {
            Column() {
              Row({ space: 16 }) {
                Text($r('app.string.field_auto_update')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).layoutWeight(1)
                  .fontColor($r('sys.color.font_primary'))
                Toggle({ type: ToggleType.Switch, isOn: this.draft.autoUpdate })
                  .selectedColor(this.appStyle.palette.brand)
                  .onChange((enabled: boolean): void => { this.draft.autoUpdate = enabled; })
              }
              .height(56).padding({ left: 16, right: 16 }).width('100%')
              if (this.draft.autoUpdate) {
                Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
                Row({ space: 16 }) {
                  Text($r('app.string.profile_update_interval')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                  Row({ space: 4 }) {
                    TextInput({ text: this.draft.interval, placeholder: $r('app.string.profile_field_required') })
                      .fontFamily(this.appStyle.fontFamily)
                      .type(InputType.Number).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                      .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                      .onChange((text: string): void => { this.draft.interval = text; })
                    Text($r('app.string.profile_minutes')).fontFamily(this.appStyle.fontFamily).fontSize(15).lineHeight(20).fontColor($r('sys.color.font_secondary'))
                  }
                  .layoutWeight(1)
                }
                .padding({ left: 16, right: 16 }).width('100%')
              }
            }
            .backgroundColor(this.appStyle.palette.cardBackground)
            .borderRadius(24).clip(true)
          }
          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text($r('app.string.profile_source_title')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
              if (this.draft.content !== undefined) {
                Text($r('app.string.profile_source_draft')).fontFamily(this.appStyle.fontFamily).fontSize(13).lineHeight(18).fontColor($r('sys.color.font_secondary'))
              } else if ((this.store.find(this.draft.id)?.updatedAt ?? 0) > 0) {
                Text($r('app.string.profile_updated', formatDateTime(this.store.find(this.draft.id)?.updatedAt ?? 0)))
                  .fontFamily(this.appStyle.fontFamily)
                  .fontSize(13).lineHeight(18)
                  .fontColor($r('sys.color.font_secondary'))
              }
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.loadingSource) {
              LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand)
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_secondary')])
            }
          }
          .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .constraintSize({ minHeight: 56 })
          .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(24)
          .enabled(!this.loadingSource)
          .onClick((): void => { this.openSource(); })
          .bindContextMenu(this.FileMenu(), ResponseType.LongPress)
        }
        .enabled(!this.draft.saving)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 16 })
        .width('100%')
        .bindSheet($$this.sourceShown, this.SourceEditor(), {
          height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
          onWillDismiss: (action: DismissSheetAction): void => this.closeSource((): void => action.dismiss())
        })
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%').height('100%')
  }
}
