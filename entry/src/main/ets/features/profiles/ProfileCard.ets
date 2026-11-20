import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { formatBytes, formatDate } from '../../components/Format';
import { hostOf } from '../../shared/profiles/Download';
import { describeError } from './ProfileErrors';
import { ProfileItem } from './ProfileModels';

@ComponentV2
@ReusableV2
export struct ProfileCard {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: ProfileItem;
  @Param selected: boolean = false;
  @Param applying: boolean = false;
  @Param running: boolean = false;
  @Param removable: boolean = true;
  @Param currentTime: number = 0;
  @Local titleRoom: number = 0;
  @Event onSelect: () => void = (): void => {};
  @Event onEdit: () => void = (): void => {};
  @Event onRemove: () => void = (): void => {};
  @Event onCopy: () => void = (): void => {};
  @Event onShare: () => void = (): void => {};
  @Event onExport: () => void = (): void => {};
  @Event onUpdate: () => void = (): void => {};
  @Param extensionAvailable: boolean = false;
  @Event onExtension: () => void = (): void => {};
  @Event onDetails: () => void = (): void => {};
  private editIcon: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.pencil_line'));
  private updateIcon: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'));
  private contextMenuOpen: boolean = false;

  private used(): number { return (this.item.state.usage?.upload ?? 0) + (this.item.state.usage?.download ?? 0); }
  private expiry(): number { return (this.item.state.usage?.expire ?? 0) * 1000; }
  private expired(): boolean { return this.expiry() > 0 && this.expiry() <= this.currentTime; }

  @Computed
  get titleText(): string { return this.item.name || hostOf(this.item.url) || this.item.id; }

  @Computed
  get expiryChipWidth(): number {
    const context = this.getUIContext();
    return context.px2vp(context.getMeasureUtils().measureText({
      textContent: formatDate(this.expiry()), fontSize: '12fp', fontWeight: 600
    })) + 16;
  }

  @Computed
  get showsExpiry(): boolean {
    if (this.expiry() <= 0 || this.titleRoom <= 0) { return false; }
    const context = this.getUIContext();
    const measure = context.getMeasureUtils();
    const titleWidth = context.px2vp(measure.measureText({ textContent: this.titleText, fontSize: '17fp', fontWeight: 600 }));
    return this.titleRoom - this.expiryChipWidth - 8 >= Math.min(titleWidth, this.titleRoom / 2);
  }

  @Computed
  get titleMaximum(): number | string {
    if (this.titleRoom <= 0) { return '100%'; }
    return this.showsExpiry ? Math.max(0, this.titleRoom - this.expiryChipWidth - 8) : this.titleRoom;
  }

  private subtitle(): ResourceStr {
    if (this.item.isSubscription && (this.item.state.usage?.total ?? 0) > 0) {
      return `${formatBytes(this.used())} / ${formatBytes(this.item.state.usage?.total ?? 0)}`;
    }
    return this.item.isSubscription ? $r('app.string.profile_source_remote') : $r('app.string.profile_source_local');
  }

  private updated(): ResourceStr {
    if (this.item.state.updatedAt <= 0) { return ''; }
    const minutes = Math.max(0, Math.floor((this.currentTime - this.item.state.updatedAt) / 60000));
    if (minutes >= 525600) { return $r('app.string.profile_updated_years', Math.floor(minutes / 525600)); }
    if (minutes >= 43200) { return $r('app.string.profile_updated_months', Math.floor(minutes / 43200)); }
    if (minutes >= 1440) { return $r('app.string.profile_updated_days', Math.floor(minutes / 1440)); }
    if (minutes >= 60) { return $r('app.string.profile_updated_hours', Math.floor(minutes / 60)); }
    if (minutes >= 1) { return $r('app.string.profile_updated_minutes', minutes); }
    return $r('app.string.profile_updated_now');
  }

  @Builder
  DetailsMenu() {
    Menu() {
      if (this.extensionAvailable) {
        MenuItem({ content: $r('app.string.profile_extension') }).onClick((): void => this.onExtension())
      }
      MenuItem({ content: $r('app.string.profile_details_title') }).onClick((): void => this.onDetails())
      if (this.item.isSubscription) {
        MenuItem({ content: $r('app.string.action_copy_link') }).onClick((): void => this.onCopy())
        MenuItem({ content: $r('app.string.profile_qr_share') }).onClick((): void => this.onShare())
      }
      MenuItem({ content: $r('app.string.profile_export') }).onClick((): void => this.onExport())
    }
  }

  @Builder
  MoreMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit'), symbolStartIcon: this.editIcon })
        .enabled(!this.item.updating)
        .onClick((): void => this.onEdit())
      if (this.item.isSubscription) {
        MenuItem({ content: $r('app.string.action_update'), symbolStartIcon: this.updateIcon })
          .enabled(!this.item.updating)
          .onClick((): void => this.onUpdate())
      }
      MenuItem({ content: $r('app.string.action_more'), builder: this.DetailsMenu })
      MenuItem({ content: $r('app.string.action_delete') })
        .contentFontColor($r('app.color.status_error'))
        .enabled(this.removable && !this.item.updating)
        .onClick((): void => this.onRemove())
    }
    .enabled(!this.item.updating)
  }

  @Builder
  CardContent() {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.titleText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(17)
            .lineHeight(22)
            .fontWeight(600)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.titleMaximum })
          if (this.showsExpiry) {
            Text(formatDate(this.expiry()))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(12)
              .lineHeight(16)
              .fontWeight(600)
              .fontColor(this.expired() ? $r('app.color.status_error') : this.appStyle.palette.brand)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor(this.expired() ? $r('app.color.profile_expiry_error_tonal') : this.appStyle.palette.profileExpiryTonal)
              .borderRadius(1000)
              .maxLines(1)
              .accessibilityText($r('app.string.usage_expire', formatDate(this.expiry())))
          }
        }
        .width('100%')
        .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => { this.titleRoom = Number(next.width ?? 0); })
        Text(this.item.state.error !== undefined ? describeError(this.item.state.error ?? 'network') : this.subtitle())
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor(this.item.state.error !== undefined ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.applying || this.item.updating) {
        LoadingProgress().width(24).height(24).color(this.appStyle.palette.brand)
      } else {
        Text(this.running && !this.selected ? $r('app.string.profile_running') : this.updated())
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor(this.running && !this.selected ? this.appStyle.palette.brand : $r('sys.color.font_secondary'))
          .maxLines(1)
      }
      if (this.selected) {
        Row() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(18)
            .fontColor([this.appStyle.palette.onBrand])
        }
        .width(24)
        .height(24)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.appStyle.palette.brand)
        .borderRadius(12)
        .accessibilityText($r('app.string.profile_current'))
      }
    }
    .width('100%')
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      this.CardContent()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .constraintSize({ minHeight: 64 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(24)
    .accessibilitySelected(this.selected)
    .onClick((): void => { if (!this.contextMenuOpen) { this.onSelect(); } })
    .bindContextMenu(this.MoreMenu(), ResponseType.LongPress, {
      onWillAppear: (): void => { this.contextMenuOpen = true; },
      onDidDisappear: (): void => { this.contextMenuOpen = false; }
    })
  }
}
