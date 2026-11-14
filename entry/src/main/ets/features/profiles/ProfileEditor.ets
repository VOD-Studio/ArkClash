import { formatDateTime } from '../../components/Format';
import { PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';
import { ProfileDraft } from './ProfileDraft';
import { ProfileEdit, ProfileStore } from './Profiles';
import { ProfileSheetHeader } from './ProfileSheetHeader';

@ComponentV2
export struct ProfileEditor {
  @Param @Require store: ProfileStore;
  @Param @Require draft: ProfileDraft;
  @Event onSaved: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local sourceShown: boolean = false;
  @Local sourceText: string = '';
  @Local sourceOriginal: string = '';
  @Local sourceError: string = '';
  @Local loadingSource: boolean = false;
  @Local validating: boolean = false;

  aboutToAppear(): void { this.draft.save = (): Promise<boolean> => this.save(); }
  aboutToDisappear(): void { this.draft.save = undefined; }

  private async openSource(): Promise<void> {
    this.loadingSource = true;
    this.draft.error = '';
    try {
      this.sourceText = this.draft.content ?? await this.store.source(this.draft.id);
      this.sourceOriginal = this.sourceText;
      this.sourceError = '';
      this.sourceShown = true;
    } catch (e) { this.draft.error = errorString(e as Object); }
    finally { this.loadingSource = false; }
  }

  private async pickSource(): Promise<void> {
    this.loadingSource = true;
    try {
      const text = await this.store.pickSource();
      if (text !== undefined) {
        this.sourceOriginal = this.draft.content ?? await this.store.source(this.draft.id);
        this.sourceText = text;
        this.sourceError = '';
        this.sourceShown = true;
      }
    } catch (e) { this.draft.error = errorString(e as Object); }
    finally { this.loadingSource = false; }
  }

  private async saveSource(): Promise<boolean> {
    if (this.validating) { return false; }
    this.validating = true;
    const failure = await this.store.validateSource(this.sourceText);
    this.validating = false;
    if (failure !== undefined) { this.sourceError = failure; return false; }
    if (this.sourceText !== this.sourceOriginal) { this.draft.content = this.sourceText; }
    this.sourceOriginal = this.sourceText;
    this.sourceShown = false;
    return true;
  }

  private closeSource(dismiss: () => void): void {
    if (this.validating) { return; }
    if (this.sourceText === this.sourceOriginal) { dismiss(); return; }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.profile_unsaved_title'),
      message: $r('app.string.profile_unsaved_message'),
      autoCancel: false,
      buttons: [
        { value: $r('app.string.profile_discard'), action: (): void => { dismiss(); } },
        { value: $r('app.string.profile_keep_editing'), action: (): void => {} },
        { value: $r('app.string.action_save'), action: (): void => {
          this.saveSource().then((saved: boolean): void => { if (saved) { dismiss(); } });
        } }
      ]
    });
  }

  private async save(): Promise<boolean> {
    if (this.draft.saving) { return false; }
    this.draft.saving = true;
    this.draft.error = '';
    try {
      if (this.draft.content !== undefined && this.draft.subscription && this.draft.autoUpdate) {
        this.draft.autoUpdate = !(await this.askDisableAutoUpdate());
      }
      const edit: ProfileEdit = { name: this.draft.name, url: this.draft.link,
        autoUpdate: this.draft.autoUpdate, intervalMinutes: Number(this.draft.interval),
        content: this.draft.content, baseContentRevision: this.draft.baseContentRevision,
        baseName: this.draft.baseName, baseUrl: this.draft.baseLink };
      const failure = await this.store.edit(this.draft.id, edit);
      if (failure !== undefined) {
        this.draft.error = failure;
        if (failure === 'metadata_saved') { this.draft.saved(); }
        return false;
      }
      this.draft.saved();
      this.onSaved();
      return true;
    } finally { this.draft.saving = false; }
  }

  private askDisableAutoUpdate(): Promise<boolean> {
    return new Promise<boolean>((resolve: (disabled: boolean) => void): void => {
      this.getUIContext().showAlertDialog({
        message: $r('app.string.profile_manual_auto_update'), autoCancel: false,
        primaryButton: { value: $r('app.string.profile_keep_auto_update'), action: (): void => resolve(false) },
        secondaryButton: { value: $r('app.string.profile_disable_auto_update'), action: (): void => resolve(true) }
      });
    });
  }

  @Builder
  SourceEditor() {
    Column({ space: 12 }) {
      ProfileSheetHeader({ titleText: this.draft.name, saving: this.validating,
        onSave: (): void => { this.saveSource(); },
        onClose: (): void => this.closeSource((): void => { this.sourceShown = false; }) })
      if (this.sourceError !== '') {
        Text(describeError(this.sourceError))
          .fontColor($r('app.color.status_error'))
          .padding(12)
          .backgroundColor($r('app.color.error_soft'))
          .width('100%')
      }
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
          if (this.draft.error !== '') {
            Text(describeError(this.draft.error))
              .fontSize(13).lineHeight(18)
              .fontColor($r('app.color.status_error'))
              .padding(12)
              .backgroundColor($r('app.color.error_soft'))
              .width('100%')
          }
          Column() {
            Row({ space: 16 }) {
              Text($r('app.string.field_name')).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
              TextInput({ text: this.draft.name, placeholder: $r('app.string.profile_field_required') })
                .maxLength(64).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                .enterKeyType(EnterKeyType.Next)
                .onChange((text: string): void => { this.draft.name = text; })
            }
            .padding({ left: 16, right: 16 }).width('100%')
            if (this.draft.subscription) {
              Row().height(0.5).width('100%').backgroundColor($r('app.color.divider')).margin({ left: 16, right: 14 })
              Row({ space: 16 }) {
                Text($r('app.string.field_link')).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                TextInput({ text: this.draft.link, placeholder: $r('app.string.profile_field_required') })
                  .maxLength(2048).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                  .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Next)
                  .onChange((text: string): void => { this.draft.link = text; })
              }
              .padding({ left: 16, right: 16 }).width('100%')
            }
          }
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(24).clip(true)
          if (this.draft.subscription) {
            Column() {
              Row({ space: 16 }) {
                Text($r('app.string.field_auto_update')).fontSize(17).lineHeight(22).layoutWeight(1)
                  .fontColor($r('sys.color.font_primary'))
                Toggle({ type: ToggleType.Switch, isOn: this.draft.autoUpdate })
                  .selectedColor($r('app.color.brand'))
                  .onChange((enabled: boolean): void => { this.draft.autoUpdate = enabled; })
              }
              .height(56).padding({ left: 16, right: 16 }).width('100%')
              if (this.draft.autoUpdate) {
                Row().height(0.5).width('100%').backgroundColor($r('app.color.divider')).margin({ left: 16, right: 14 })
                Row({ space: 16 }) {
                  Text($r('app.string.profile_update_interval')).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                  Row({ space: 4 }) {
                    TextInput({ text: this.draft.interval, placeholder: $r('app.string.profile_field_required') })
                      .type(InputType.Number).fontSize(17).height(56).layoutWeight(1).textAlign(TextAlign.End).padding(0)
                      .fontColor($r('sys.color.font_primary')).backgroundColor(Color.Transparent)
                      .onChange((text: string): void => { this.draft.interval = text; })
                    Text($r('app.string.profile_minutes')).fontSize(15).lineHeight(20).fontColor($r('sys.color.font_secondary'))
                  }
                  .layoutWeight(1)
                }
                .padding({ left: 16, right: 16 }).width('100%')
              }
            }
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(24).clip(true)
          }
          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text($r('app.string.profile_source_title')).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
              if (this.draft.content !== undefined) {
                Text($r('app.string.profile_source_draft')).fontSize(13).lineHeight(18).fontColor($r('sys.color.font_secondary'))
              } else if ((this.store.find(this.draft.id)?.updatedAt ?? 0) > 0) {
                Text($r('app.string.profile_updated', formatDateTime(this.store.find(this.draft.id)?.updatedAt ?? 0)))
                  .fontSize(13).lineHeight(18)
                  .fontColor($r('sys.color.font_secondary'))
              }
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.loadingSource) {
              LoadingProgress().width(20).height(20).color($r('app.color.brand'))
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_secondary')])
            }
          }
          .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .constraintSize({ minHeight: 56 })
          .backgroundColor($r('app.color.card_background')).borderRadius(24)
          .enabled(!this.loadingSource)
          .onClick((): void => { this.openSource(); })
          .bindContextMenu(this.FileMenu(), ResponseType.LongPress)
        }
        .enabled(!this.draft.saving)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 16 })
        .width('100%')
        .bindSheet($$this.sourceShown, this.SourceEditor(), {
          height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false,
          onWillDismiss: (action: DismissSheetAction): void => this.closeSource((): void => action.dismiss())
        })
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
  }
}
