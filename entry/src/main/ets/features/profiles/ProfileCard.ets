import { formatBytes, formatDate, formatDateTime } from '../../components/Format';
import { CARD } from '../../components/Theme';
import { hostOf } from '../../shared/profiles/Download';
import { describeError } from './ProfileErrors';
import { ProfileItem } from './ProfileModels';

@ComponentV2
@ReusableV2
export struct ProfileCard {
  @Param @Require item: ProfileItem;
  @Param selected: boolean = false;
  @Param applying: boolean = false;
  @Param running: boolean = false;
  @Param removable: boolean = true;
  @Event onSelect: () => void = (): void => {};
  @Event onEdit: () => void = (): void => {};
  @Event onRemove: () => void = (): void => {};
  @Event onCopy: () => void = (): void => {};
  @Event onExport: () => void = (): void => {};
  @Event onUpdate: () => void = (): void => {};

  private used(): number { return (this.item.state.usage?.upload ?? 0) + (this.item.state.usage?.download ?? 0); }
  private expiry(): number { return (this.item.state.usage?.expire ?? 0) * 1000; }
  private expired(): boolean { return this.expiry() > 0 && this.expiry() <= Date.now(); }

  @Builder
  MoreMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit') }).onClick((): void => this.onEdit())
      if (this.item.isSubscription) {
        MenuItem({ content: $r('app.string.action_copy_link') }).onClick((): void => this.onCopy())
      }
      MenuItem({ content: $r('app.string.profile_export') }).onClick((): void => this.onExport())
      MenuItem({ content: $r('app.string.action_delete') })
        .enabled(this.removable)
        .onClick((): void => this.onRemove())
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(22)
          .fontColor([$r('app.color.brand')])
        Column({ space: 4 }) {
          Text(this.item.name || hostOf(this.item.url) || this.item.id)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.item.isSubscription ? hostOf(this.item.url) : $r('app.string.profile_source_local'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.applying || this.item.updating) {
          LoadingProgress().width(22).height(22).color($r('app.color.brand'))
        } else if (this.selected) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(20)
            .fontColor([$r('app.color.brand')])
            .accessibilityText($r('app.string.profile_current'))
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.action_more'))
        .bindMenu(this.MoreMenu())
      }
      .width('100%')
      if (this.running) {
        Text($r('app.string.profile_running'))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
      }
      if ((this.item.state.usage?.total ?? 0) > 0) {
        Text($r('app.string.usage_used', formatBytes(this.used()), formatBytes(this.item.state.usage?.total ?? 0)))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      if (this.expiry() > 0) {
        Text($r('app.string.usage_expire', formatDate(this.expiry())))
          .fontSize(12)
          .fontColor(this.expired() ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
      }
      if (this.item.state.updatedAt > 0) {
        Text($r('app.string.profile_updated', formatDateTime(this.item.state.updatedAt)))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      if (this.item.state.error !== undefined) {
        Text(describeError(this.item.state.error ?? 'network'))
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
      }
      if (this.item.isSubscription) {
        Button($r('app.string.action_update'), { type: ButtonType.Capsule })
          .width('100%')
          .height(40)
          .fontColor($r('app.color.brand'))
          .backgroundColor($r('app.color.brand_soft'))
          .enabled(!this.item.updating)
          .onClick((): void => { this.onUpdate(); })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .border({ width: 1.5, color: this.selected ? $r('app.color.brand') : Color.Transparent, radius: 16 })
    .accessibilitySelected(this.selected)
    .onClick((): void => this.onSelect())
  }
}
