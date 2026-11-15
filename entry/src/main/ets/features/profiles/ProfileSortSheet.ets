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
  @Local failure: string = '';
  @Local saving: boolean = false;
  private order: ProfileItem[] = [];
  private rows: ListSource<ProfileItem> = new ListSource<ProfileItem>();

  aboutToAppear(): void {
    this.order = this.store.items.slice();
    this.rows.replace(this.order);
  }

  private move(from: number, to: number): void {
    if (from < 0 || to < 0 || from >= this.order.length || to >= this.order.length || from === to) { return; }
    const moved = this.order.splice(from, 1)[0];
    this.order.splice(to, 0, moved);
    this.rows.replace(this.order.slice());
  }

  private async save(): Promise<void> {
    this.saving = true;
    const failure = await this.store.reorder(this.order.map((item: ProfileItem): string => item.id));
    this.saving = false;
    if (failure === undefined) { this.onSaved(); } else { this.failure = failure; }
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: $r('app.string.profile_sort'), saving: this.saving,
        onSave: (): void => { this.save(); }, onClose: (): void => this.onClose() })
      if (this.failure !== '') {
        Text(describeError(this.failure))
          .fontSize(13).lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .padding(12).backgroundColor($r('app.color.error_soft')).width('100%')
          .margin({ left: 16, right: 16, bottom: 24 })
      }
      List({ space: 0 }) {
        LazyForEach(this.rows, (item: ProfileItem, index: number) => {
          ListItem() {
            ProfileSortRow({ item: item, first: index === 0, last: index === this.order.length - 1 })
          }
        }, (item: ProfileItem): string => item.id)
          .onMove((from: number, to: number): void => this.move(from, to))
      }
      .layoutWeight(1)
      .width('100%')
      .enabled(!this.saving)
      .scrollBar(BarState.Off)
      .cachedCount(2)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      .contentStartOffset(24)
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
  @Param @Require item: ProfileItem;
  @Param first: boolean = false;
  @Param last: boolean = false;

  build() {
    Column() {
      Row({ space: 16 }) {
        Text(this.item.name)
          .fontSize(17).lineHeight(22)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.font_primary'))
        SymbolGlyph($r('sys.symbol.sort'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_secondary')])
          .width(48)
          .height(56)
      }
      .width('100%').height(56).padding({ left: 16 })
      if (!this.last) {
        Row().height(0.5).width('100%').backgroundColor($r('app.color.divider')).margin({ left: 16, right: 14 })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius({ topLeft: this.first ? 24 : 0, topRight: this.first ? 24 : 0,
      bottomLeft: this.last ? 24 : 0, bottomRight: this.last ? 24 : 0 })
  }
}
