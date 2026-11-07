/** 分组列表里的一行：左图标、标题、右侧值或箭头。点按只改背景色。 */
@ComponentV2
export struct ListRow {
  @Param icon: Resource | undefined = undefined;
  @Param title: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param chevron: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon)
          .fontSize(22)
          .fontColor([$r('sys.color.font_primary')])
      }
      Text(this.title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.value !== '') {
        Text(this.value)
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '55%' })
      }
      if (this.chevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 12 })
    .stateStyles({
      pressed: {
        .backgroundColor($r('sys.color.interactive_pressed'))
      },
      normal: {
        .backgroundColor(Color.Transparent)
      }
    })
    .onClick(() => this.onTap())
  }
}
