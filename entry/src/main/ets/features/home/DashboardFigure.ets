import { AppearanceState, appAppearance } from '../../components/AppearanceState';
@ComponentV2
export struct DashboardFigure {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param figureText: string = '—';
  @Param label: ResourceStr = '';
  @Param figureSize: number = 20;
  @Param figureLeading: number = 25;
  @Param figureWeight: number = 600;
  @Param centered: boolean = false;

  build() {
    Column({ space: this.centered ? 2 : 0 }) {
      Text(this.figureText)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(this.figureSize)
        .lineHeight(this.figureLeading)
        .fontWeight(this.figureWeight)
        .fontFeature('"tnum" on')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(12)
        .lineHeight(16)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(this.centered ? HorizontalAlign.Center : HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
  }
}
