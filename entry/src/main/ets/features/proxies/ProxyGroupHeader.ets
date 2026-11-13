import { ProxyGroupView } from './ProxyView';

@ComponentV2
export struct ProxyGroupHeader {
  @Param @Require group: ProxyGroupView;
  @Param online: boolean = false;
  @Param offlineWritable: boolean = false;
  @Param showLocate: boolean = true;
  @Param collapsible: boolean = true;
  @Event onToggle: () => void = () => {};
  @Event onLocate: () => void = () => {};
  @Event onTest: () => void = () => {};
  @Event onClearPin: () => void = () => {};
  @Local iconFailed: boolean = false;

  @Monitor('group.icon')
  resetIcon(): void {
    this.iconFailed = false;
  }

  build() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          if (this.group.iconStyle !== 'hidden') {
            Stack() {
              if (this.group.icon !== '' && !this.iconFailed) {
                Image(this.group.icon)
                  .width(24)
                  .height(24)
                  .objectFit(ImageFit.Contain)
                  .onError(() => { this.iconFailed = true; })
              } else {
                Text(this.group.name.slice(0, 1))
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.brand'))
              }
            }
            .width(36)
            .height(36)
            .borderRadius(10)
            .backgroundColor(this.group.iconStyle === 'filled' ? $r('app.color.brand_soft') : Color.Transparent)
          }
          Column({ space: 4 }) {
            Text(this.group.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.group.now === '' ? this.group.type : `${this.group.type} · ${this.group.now}`)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (this.group.actualRetired) {
              Text($r('app.string.proxy_actual_retired'))
                .fontSize(11)
                .fontColor($r('app.color.warning'))
                .width('100%')
            }
            if (this.group.pinned !== '') {
              Text($r('app.string.proxy_pinned_name', this.group.pinned))
                .fontSize(11)
                .fontColor($r('app.color.brand'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (this.collapsible) {
            SymbolGlyph(this.group.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(12)
              .fontColor([$r('sys.color.font_secondary')])
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .padding({ left: 4, right: 4, top: 12, bottom: 12 })
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.group.name)
      .accessibilityDescription(this.group.expanded ? $r('app.string.proxy_collapse_group') : $r('app.string.proxy_expand_group'))
      .enabled(this.collapsible)
      .onClick(() => this.onToggle())
      if (this.group.expanded && this.showLocate) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(18)
            .fontColor([$r('app.color.brand')])
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.proxy_locate_selected'))
        .onClick(() => this.onLocate())
      }
      if (this.group.pinned !== '') {
        Button($r('app.string.proxy_clear_pin'))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .backgroundColor(Color.Transparent)
          .enabled(this.online || this.offlineWritable)
          .onClick(() => this.onClearPin())
      }
      if (this.group.expanded) {
        Button({ type: ButtonType.Circle }) {
          if (this.group.testing) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(18)
              .fontColor([$r('sys.color.font_secondary')])
          } else {
            SymbolGlyph($r('sys.symbol.bolt'))
              .fontSize(18)
              .fontColor([$r('app.color.brand')])
          }
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.proxy_test_current_group'))
        .enabled(this.online && !this.group.testing)
        .onClick(() => this.onTest())
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
