import { PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';
import { ProfileDraft } from './ProfileDraft';
import { ProfileEdit, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileEditor {
  @Param @Require store: ProfileStore;
  @Param @Require draft: ProfileDraft;
  @Event onSaved: () => void = (): void => {};
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

  private sourceDismiss(action: DismissSheetAction): void {
    if (this.validating) { return; }
    if (this.sourceText === this.sourceOriginal) { action.dismiss(); return; }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.profile_unsaved_title'),
      message: $r('app.string.profile_unsaved_message'),
      autoCancel: false,
      buttons: [
        { value: $r('app.string.profile_discard'), action: (): void => { action.dismiss(); } },
        { value: $r('app.string.profile_keep_editing'), action: (): void => {} },
        { value: $r('app.string.action_save'), action: (): void => {
          this.saveSource().then((saved: boolean): void => { if (saved) { action.dismiss(); } });
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
      TextArea({ text: this.sourceText })
        .fontFamily('monospace')
        .fontSize(14)
        .layoutWeight(1)
        .width('100%')
        .onChange((text: string): void => { this.sourceText = text; })
      if (this.sourceError !== '') {
        Text(describeError(this.sourceError)).fontColor($r('app.color.status_error')).width('100%')
      }
      Button($r('app.string.action_save'), { type: ButtonType.Capsule })
        .width('100%').height(48).enabled(!this.validating)
        .backgroundColor($r('app.color.brand')).fontColor($r('app.color.on_brand'))
        .onClick((): void => { this.saveSource(); })
    }
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
    .height('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text($r('app.string.field_name')).fontColor($r('sys.color.font_secondary')).width('100%')
        TextInput({ text: this.draft.name }).maxLength(64).height(48)
          .onChange((text: string): void => { this.draft.name = text; })
        if (this.draft.subscription) {
          Text($r('app.string.field_link')).fontColor($r('sys.color.font_secondary')).width('100%')
          TextInput({ text: this.draft.link }).type(InputType.Password).showPasswordIcon(true).maxLength(2048).height(48)
            .onChange((text: string): void => { this.draft.link = text; })
          Row() {
            Text($r('app.string.field_auto_update')).layoutWeight(1).fontColor($r('sys.color.font_primary'))
            Toggle({ type: ToggleType.Switch, isOn: this.draft.autoUpdate })
              .onChange((enabled: boolean): void => { this.draft.autoUpdate = enabled; })
          }.height(48).width('100%')
          if (this.draft.autoUpdate) {
            Text($r('app.string.profile_interval_minutes')).fontColor($r('sys.color.font_secondary')).width('100%')
            TextInput({ text: this.draft.interval }).type(InputType.Number).height(48)
              .onChange((text: string): void => { this.draft.interval = text; })
          }
        }
        Row({ space: 8 }) {
          Button($r('app.string.profile_edit_source')).layoutWeight(1).height(44)
            .fontColor($r('sys.color.font_primary')).backgroundColor($r('app.color.track'))
            .enabled(!this.loadingSource).onClick((): void => { this.openSource(); })
          Button($r('app.string.profile_upload_source')).layoutWeight(1).height(44)
            .fontColor($r('sys.color.font_primary')).backgroundColor($r('app.color.track'))
            .enabled(!this.loadingSource).onClick((): void => { this.pickSource(); })
        }
        if (this.draft.content !== undefined) {
          Text($r('app.string.profile_source_draft')).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.draft.error !== '') {
          Text(describeError(this.draft.error)).fontSize(13).fontColor($r('app.color.status_error')).width('100%')
        }
        Button($r('app.string.action_save'), { type: ButtonType.Capsule })
          .width('100%').height(48).backgroundColor($r('app.color.brand')).fontColor($r('app.color.on_brand'))
          .enabled(!this.draft.saving && !this.loadingSource)
          .onClick((): void => { this.save(); })
      }
      .enabled(!this.draft.saving)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
      .bindSheet($$this.sourceShown, this.SourceEditor(), {
        title: { title: $r('app.string.profile_source_title') }, height: SheetSize.LARGE,
        systemMaterial: sheetMaterial(), showClose: true,
        onWillDismiss: (action: DismissSheetAction): void => this.sourceDismiss(action)
      })
    }
    .width('100%').height('100%')
  }
}
