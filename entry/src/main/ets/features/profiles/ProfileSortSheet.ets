import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListSource } from '../../components/ListSource';
import { PAGE_GUTTER } from '../../components/Theme';
import { describeError } from './ProfileErrors';
import { ProfileItem, ProfileStore } from './Profiles';
import { ProfileSheetHeader } from './ProfileSheetHeader';

@ComponentV2
export struct ProfileSortSheet {
  @Param @Require store: ProfileStore;
  @Event onSaved: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local saving: boolean = false;
  @Local order: ProfileItem[] = [];
  @Local draggingId: string = '';
  private rows: ListSource<ProfileItem> = new ListSource<ProfileItem>();
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.order = this.store.items.slice();
    this.rows.replace(this.order);
  }
  aboutToDisappear(): void { this.visible = false; }

  private move(from: number, to: number): void {
    if (from < 0 || to < 0 || from >= this.order.length || to >= this.order.length || from === to) { return; }
    const moved = this.order.splice(from, 1)[0];
    this.order.splice(to, 0, moved);
    this.rows.replace(this.order);
  }

  private async save(): Promise<void> {
    if (this.saving) { return; }
    this.saving = true;
    const failure = await this.store.reorder(this.order.map((item: ProfileItem): string => item.id));
    this.saving = false;
    if (!this.visible) { return; }
    if (failure === undefined) { this.onSaved(); }
    else { this.getUIContext().getPromptAction().showToast({ message: describeError(failure) }); }
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: $r('app.string.profile_sort'), saving: this.saving,
        onSave: (): void => { this.save(); }, onClose: (): void => this.onClose() })
      List({ space: 0 }) {
        LazyForEach(this.rows, (item: ProfileItem) => {
          ListItem() {
            ProfileSortRow({ item: item, first: this.order[0]?.id === item.id,
              last: this.order[this.order.length - 1]?.id === item.id, dragging: this.draggingId === item.id })
          }
        }, (item: ProfileItem): string => item.id)
          .onMove((from: number, to: number): void => this.move(from, to), {
            onLongPress: (index: number): void => { this.draggingId = this.order[index]?.id ?? ''; },
            onDrop: (_index: number): void => { this.draggingId = ''; }
          })
      }
      .layoutWeight(1)
      .width('100%')
      .enabled(!this.saving)
      .scrollBar(BarState.Off)
      .cachedCount(2)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      .contentStartOffset(8)
      .contentEndOffset(32)
      .accessibilityText($r('app.string.profile_sort_hint'))
    }
    .height('100%')
    .width('100%')
  }
}

@ComponentV2
@ReusableV2
struct ProfileSortRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: ProfileItem;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param dragging: boolean = false;

  build() {
    Column() {
      Row({ space: 16 }) {
        Text(this.item.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17).lineHeight(22)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.font_primary'))
        SymbolGlyph($r('sys.symbol.sort'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_secondary')])
          .width(40)
          .height(56)
      }
      .width('100%').constraintSize({ minHeight: 56 })
      if (!this.last) {
        Divider().strokeWidth(0.5).color(this.appStyle.palette.divider).opacity(this.dragging ? 0 : 1)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius({ topLeft: this.first || this.dragging ? 24 : 0, topRight: this.first || this.dragging ? 24 : 0,
      bottomLeft: this.last || this.dragging ? 24 : 0, bottomRight: this.last || this.dragging ? 24 : 0 })
  }
}
