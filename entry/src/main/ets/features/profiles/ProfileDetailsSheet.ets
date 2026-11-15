import { sheetMaterial } from '../../components/Theme';
import { ProfileDetails } from './ProfileDetails';
import { ProfileDraft } from './ProfileDraft';
import { confirmProfileEditorDismiss, ProfileEditor } from './ProfileEditor';
import { ProfileItem, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileDetailsSheet {
  @Param @Require store: ProfileStore;
  @Param @Require item: ProfileItem;
  @Local editing: boolean = false;
  @Local draft: ProfileDraft | undefined = undefined;

  @Builder
  Editor() {
    if (this.draft !== undefined) {
      ProfileEditor({ store: this.store, draft: this.draft,
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
      height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false,
      onWillDismiss: (action: DismissSheetAction): void =>
        confirmProfileEditorDismiss(this.getUIContext(), this.draft, (): void => action.dismiss()),
      onDisappear: (): void => { this.draft = undefined; }
    })
  }
}
