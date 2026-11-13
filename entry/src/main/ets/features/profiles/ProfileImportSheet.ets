import { PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';
import { ProfileBatchResult } from './ProfileModels';
import { ProfileStore } from './Profiles';
import { ProfileResults } from './ProfileResults';

@ComponentV2
export struct ProfileImportSheet {
  @Param @Require store: ProfileStore;
  @Param batch: boolean = false;
  @Event onDone: () => void = (): void => {};
  @Event onBusy: (busy: boolean) => void = (): void => {};
  @Local source: string = '';
  @Local label: string = '';
  @Local adding: boolean = false;
  @Local failure: string = '';
  @Local result: ProfileBatchResult | undefined = undefined;

  private async save(): Promise<void> {
    if (this.adding) { return; }
    this.adding = true;
    this.onBusy(true);
    this.failure = '';
    this.result = undefined;
    try {
      if (this.batch) {
        const result = await this.store.importLinks(this.source);
        this.result = result;
      } else {
        const failure = await this.store.addSubscription(this.source, this.label);
        if (failure === undefined) { this.onDone(); } else { this.failure = failure; }
      }
    } catch (e) { this.failure = errorString(e as Object); }
    finally { this.adding = false; this.onBusy(false); }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.batch) {
          TextArea({ text: this.source, placeholder: $r('app.string.profile_batch_hint') })
            .height(180)
            .onChange((text: string): void => { this.source = text; })
        } else {
          TextInput({ text: this.label, placeholder: $r('app.string.profile_optional_name') })
            .maxLength(64)
            .height(48)
            .onChange((text: string): void => { this.label = text; })
          TextInput({ text: this.source, placeholder: $r('app.string.subscription_link') })
            .type(InputType.Password)
            .showPasswordIcon(true)
            .maxLength(2048)
            .height(48)
            .enterKeyType(EnterKeyType.Go)
            .onChange((text: string): void => { this.source = text; })
            .onSubmit((): void => { if (!this.adding && this.source.trim() !== '') { this.save(); } })
        }
        if (this.failure !== '') {
          Text(describeError(this.failure))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
        if (this.result !== undefined) { ProfileResults({ result: this.result }) }
        if (this.adding) {
          Row({ space: 8 }) {
            LoadingProgress().width(20).height(20).color($r('app.color.brand'))
            if (this.batch) {
              Text($r('app.string.profile_batch_progress', this.store.importDone, this.store.importTotal))
                .fontColor($r('sys.color.font_secondary'))
            }
          }
        }
        Button($r('app.string.action_save_download'), { type: ButtonType.Capsule })
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .enabled(!this.adding && this.source.trim() !== '')
          .onClick((): void => { this.save(); })
      }
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }
    .width('100%')
  }
}
