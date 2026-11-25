import { AppearanceState, appAppearance } from './AppearanceState';
/** 分组列表里的一行，点按时显示按压背景。 */
@ComponentV2
export struct ListRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param icon: Resource | undefined = undefined;
  @Param title: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param trailingIcon: Resource | undefined = undefined;
  @Param chevron: boolean = true;
  @Param busy: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon)
          .fontSize(22)
          .fontColor([$r('sys.color.font_primary')])
      }
      Text(this.title)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.value !== '') {
        Text(this.value)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '55%' })
      }
      if (this.busy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(this.appStyle.palette.brand)
      } else {
        if (this.trailingIcon !== undefined) {
          SymbolGlyph(this.trailingIcon)
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')])
        }
        if (this.chevron) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_tertiary')])
        }
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
