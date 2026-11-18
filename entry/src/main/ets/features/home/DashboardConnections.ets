import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardConnections {
  @Local private appStyle: AppearanceState = appAppearance;
  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_conn_stats'), glyph: 'connections' })
      Text($r('app.string.coming_soon'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .accessibilityText($r('app.string.card_conn_stats'))
  }
}
