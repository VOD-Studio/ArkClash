import { AppearanceState, appAppearance } from '../../components/AppearanceState';
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

  @Builder
  Editor() {
    if (this.draft !== undefined) {
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
        this.draft = new ProfileDraft(this.item);
        this.editing = true;
      } })
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.editing, this.Editor, {
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
      onWillDismiss: (action: DismissSheetAction): void =>
        confirmProfileEditorDismiss(this.getUIContext(), this.draft, (): void => action.dismiss()),
      onDisappear: (): void => { this.draft = undefined; }
    })
  }
}
