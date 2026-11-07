/** 没有内容时的占位：图标、标题、说明，以及可选的一个主操作。 */
@ComponentV2
export struct EmptyState {
  @Param icon: Resource = $r('sys.symbol.doc_text');
  @Param title: ResourceStr = '';
  @Param hint: ResourceStr = '';
  @Param actionLabel: ResourceStr = '';
  @Event onAction: () => void = () => {};

  build() {
    Column({ space: 8 }) {
      SymbolGlyph(this.icon)
        .fontSize(48)
        .fontColor([$r('sys.color.font_tertiary')])
        .margin({ bottom: 8 })
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.Center)
      Text(this.hint)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
      if (this.actionLabel !== '') {
        Button(this.actionLabel, { type: ButtonType.Capsule })
          .height(44)
          .padding({ left: 24, right: 24 })
          .margin({ top: 16 })
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .padding({ left: 32, right: 32, top: 48, bottom: 48 })
    .justifyContent(FlexAlign.Center)
  }
}
