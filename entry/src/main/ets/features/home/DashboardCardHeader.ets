import { AppGlyph } from '../../components/AppGlyph';

@ComponentV2
export struct DashboardCardHeader {
  @Param title: ResourceStr = '';
  @Param glyph: string = 'profiles';
  @Param chevron: boolean = false;

  build() {
    Row({ space: 8 }) {
      AppGlyph({ name: this.glyph, iconSize: 18, iconColor: $r('sys.color.font_secondary') })
      Text(this.title)
        .fontSize(15)
        .lineHeight(20)
        .fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.chevron) {
        AppGlyph({ name: 'chevronForward', iconSize: 18, iconColor: $r('sys.color.font_secondary') })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 26 })
  }
}
