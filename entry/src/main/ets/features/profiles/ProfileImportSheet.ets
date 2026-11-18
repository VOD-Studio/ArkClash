import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';
import { ProfileBatchResult } from './ProfileModels';
import { ProfileStore } from './Profiles';
import { ProfileResults } from './ProfileResults';
import { ProfileSheetHeader } from './ProfileSheetHeader';

@ComponentV2
export struct ProfileImportSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param batch: boolean = false;
  @Event onDone: () => void = (): void => {};
  @Event onBusy: (busy: boolean) => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local source: string = '';
  @Local label: string = '';
  @Local importingMany: boolean = false;
  @Local batchSource: string = '';
  @Local adding: boolean = false;
  @Local result: ProfileBatchResult | undefined = undefined;
  @Local resultShown: boolean = false;
  private visible: boolean = false;

  aboutToAppear(): void { this.visible = true; this.importingMany = this.batch; }
  aboutToDisappear(): void { this.visible = false; }

  private toastFailure(failure: string): void {
    if (this.visible) { this.getUIContext().getPromptAction().showToast({ message: describeError(failure) }); }
  }

  private toggleBatch(): void {
    if (this.adding) { return; }
    this.importingMany = !this.importingMany;
    if (this.importingMany && this.batchSource === '') { this.batchSource = this.source; }
    this.result = undefined;
  }

  private canSave(): boolean {
    return !this.adding && (this.importingMany ? this.batchSource : this.source).trim() !== '';
  }

  private async save(): Promise<void> {
    if (this.adding) { return; }
    this.adding = true;
    this.onBusy(true);
    this.result = undefined;
    try {
      if (this.importingMany) {
        const result = await this.store.importLinks(this.batchSource);
        if (this.visible) { this.result = result; this.resultShown = true; }
      } else {
        const failure = await this.store.addSubscription(this.source, this.label);
        if (failure === undefined) { if (this.visible) { this.onDone(); } }
        else { this.toastFailure(failure); }
      }
    } catch (e) { this.toastFailure(errorString(e as Object)); }
    finally { this.adding = false; this.onBusy(false); }
  }

  @Builder
  BatchResults() {
    Column() {
      if (this.result !== undefined) { ProfileResults({ result: this.result }) }
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  @Builder
  ImportActions() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.importingMany ? $r('sys.symbol.doc_text') : $r('sys.symbol.sort'))
        .fontSize(HEADER_ICON_SIZE)
        .fontColor([$r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION)
    .systemMaterial(this.appStyle.headerMaterial())
    .enabled(!this.adding)
    .accessibilityText(this.importingMany ? $r('app.string.profile_import_single') : $r('app.string.profile_import_batch'))
    .onClick((): void => this.toggleBatch())
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: this.importingMany ? $r('app.string.profile_import_batch') : $r('app.string.profile_import_link'),
        confirmLabel: $r('app.string.action_save_download'), saving: this.adding, canSave: this.canSave(),
        actions: (): void => this.ImportActions(), onSave: (): void => { this.save(); }, onClose: (): void => this.onClose() })
      Scroll() {
        Column({ space: 24 }) {
          if (this.importingMany) {
            TextArea({ text: this.batchSource, placeholder: $r('app.string.profile_batch_hint') })
              .fontFamily(this.appStyle.fontFamily)
              .height(200)
              .fontSize(17)
              .fontColor($r('sys.color.font_primary'))
              .backgroundColor(this.appStyle.palette.cardBackground)
              .borderRadius(24)
              .onChange((text: string): void => { this.batchSource = text; })
          } else {
            Column() {
              Row({ space: 16 }) {
                Text($r('app.string.field_name')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                TextInput({ text: this.label, placeholder: $r('app.string.profile_field_optional') })
                  .fontFamily(this.appStyle.fontFamily)
                  .maxLength(64)
                  .layoutWeight(1)
                  .height(56)
                  .fontSize(17)
                  .textAlign(TextAlign.End)
                  .padding(0)
                  .fontColor($r('sys.color.font_primary'))
                  .backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Next)
                  .onChange((text: string): void => { this.label = text; })
              }
              .padding({ left: 16, right: 16 })
              .width('100%')
              Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
              Row({ space: 16 }) {
                Text($r('app.string.subscription_link')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22).fontColor($r('sys.color.font_primary'))
                TextInput({ text: this.source, placeholder: $r('app.string.profile_field_required') })
                  .fontFamily(this.appStyle.fontFamily)
                  .maxLength(2048)
                  .layoutWeight(1)
                  .height(56)
                  .fontSize(17)
                  .textAlign(TextAlign.End)
                  .padding(0)
                  .fontColor($r('sys.color.font_primary'))
                  .backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Go)
                  .onChange((text: string): void => { this.source = text; })
                  .onSubmit((): void => { if (this.canSave()) { this.save(); } })
              }
              .padding({ left: 16, right: 16 })
              .width('100%')
            }
            .backgroundColor(this.appStyle.palette.cardBackground)
            .borderRadius(24).clip(true)
          }
        }
        .enabled(!this.adding)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 20 })
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .height('100%')
    .width('100%')
    .bindSheet($$this.resultShown, this.BatchResults(), { title: { title: $r('app.string.profile_import_batch') },
      preferType: SheetType.BOTTOM, height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
  }
}
