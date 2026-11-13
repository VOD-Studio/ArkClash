@ComponentV2
export struct DashboardCardHeader {
  @Param title: ResourceStr = '';
  @Param symbol: Resource = $r('sys.symbol.doc_text');
  @Param chevron: boolean = false;

  build() {
    Row({ space: 8 }) {
      SymbolGlyph(this.symbol)
        .fontSize(18)
        .fontColor([$r('sys.color.font_secondary')])
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.chevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 28 })
    .margin({ bottom: 12 })
  }
}
