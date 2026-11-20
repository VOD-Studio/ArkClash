import { UIContext } from '@kit.ArkUI';
import { appAppearance } from '../../components/AppearanceState';
import { ProfileItem } from './ProfileModels';

@ObservedV2
export class CustomProfileDraft {
  @Trace name: string = '';
  @Trace changed: boolean = false;
  @Trace editing: boolean = false;
  @Trace busy: boolean = false;
  readonly id: string;
  readonly baseName: string;
  readonly revision: string;

  constructor(item?: ProfileItem) {
    this.id = item?.id ?? '';
    this.baseName = item?.name ?? '';
    this.name = this.baseName;
    this.revision = item?.contentRevision ?? '';
  }

  dirty(): boolean { return this.changed || this.name !== this.baseName || this.editing; }
}

export function confirmCustomDismiss(context: UIContext, draft: CustomProfileDraft | undefined,
  dismiss: () => void): void {
  if (draft?.busy === true) { return; }
  if (draft?.dirty() !== true) { dismiss(); return; }
  let discard = false;
  context.showActionSheet({
    title: $r('app.string.custom_discard_title'), message: $r('app.string.profile_unsaved_message'),
    alignment: DialogAlignment.Bottom, systemMaterial: appAppearance.sheetMaterial(),
    sheets: [{ title: $r('app.string.profile_discard'), action: (): void => { discard = true; } }],
    confirm: { value: $r('app.string.profile_keep_editing'), defaultFocus: true, action: (): void => {} },
    onWillDismiss: (action: DismissDialogAction): void => action.dismiss(),
    onDidDisappear: (): void => { if (discard) { dismiss(); } }
  });
}
