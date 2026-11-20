import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { confirmCustomDismiss, CustomProfileDraft } from './CustomProfileDraft';
import { CustomProfileEditor } from './CustomProfileEditor';
import { ProfileDetails } from './ProfileDetails';
import { ProfileDraft } from './ProfileDraft';
import { confirmProfileEditorDismiss, ProfileEditor } from './ProfileEditor';
import { ProfileItem, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileDetailsSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require item: ProfileItem;
  @Param @Require visible: boolean;
  @Local editing: boolean = false;
  @Local draft: ProfileDraft | undefined = undefined;
  @Local customDraft: CustomProfileDraft | undefined = undefined;

  @Builder
  Editor() {
    if (this.customDraft !== undefined) {
      CustomProfileEditor({ store: this.store, draft: this.customDraft,
        onClose: (): void => { this.editing = false; } })
    } else if (this.draft !== undefined) {
      ProfileEditor({ store: this.store, draft: this.draft, visible: this.visible && this.editing,
        onSaved: (): void => {
          if (this.draft !== undefined) { this.draft.saving = false; }
          this.editing = false;
        },
        onClose: (): void => confirmProfileEditorDismiss(this.getUIContext(), this.draft,
          (): void => { this.editing = false; }) })
    }
  }

  build() {
    Column() {
      ProfileDetails({ store: this.store, item: this.item, onEdit: (): void => {
        if (this.item.type === 'custom') { this.customDraft = new CustomProfileDraft(this.item); }
        else { this.draft = new ProfileDraft(this.item); }
        this.editing = true;
      } })
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.editing, this.Editor, {
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
      onWillDismiss: (action: DismissSheetAction): void => {
        if (this.customDraft !== undefined) {
          confirmCustomDismiss(this.getUIContext(), this.customDraft, (): void => action.dismiss());
        } else { confirmProfileEditorDismiss(this.getUIContext(), this.draft, (): void => action.dismiss()); }
      },
      onDisappear: (): void => { this.draft = undefined; this.customDraft = undefined; }
    })
  }
}
