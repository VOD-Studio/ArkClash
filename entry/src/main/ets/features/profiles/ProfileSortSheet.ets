import { ListSource } from '../../components/ListSource';
import { PAGE_GUTTER } from '../../components/Theme';
import { describeError } from './ProfileErrors';
import { ProfileItem, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileSortSheet {
  @Param @Require store: ProfileStore;
  @Event onSaved: () => void = (): void => {};
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
    Column({ space: 12 }) {
      Text($r('app.string.profile_sort_hint'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      List({ space: 8 }) {
        LazyForEach(this.rows, (item: ProfileItem) => {
          ListItem() {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.sort'))
                .fontSize(18)
                .fontColor([$r('sys.color.font_secondary')])
              Text(item.name)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('sys.color.font_primary'))
            }
            .width('100%')
            .height(56)
            .padding({ left: 12, right: 12 })
            .backgroundColor($r('app.color.tile_background'))
            .borderRadius(12)
          }
        }, (item: ProfileItem): string => item.id)
          .onMove((from: number, to: number): void => this.move(from, to))
      }
      .layoutWeight(1)
      .width('100%')
      if (this.failure !== '') {
        Text(describeError(this.failure)).fontColor($r('app.color.status_error')).width('100%')
      }
      Button($r('app.string.action_save'), { type: ButtonType.Capsule })
        .height(48)
        .width('100%')
        .enabled(!this.saving)
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.on_brand'))
        .onClick((): void => { this.save(); })
    }
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }
}
