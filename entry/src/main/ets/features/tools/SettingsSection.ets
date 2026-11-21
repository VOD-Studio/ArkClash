import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { CARD_RADIUS } from '../../components/Theme';

@ComponentV2
export struct SettingsSection {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param heading: ResourceStr = '';
  @Param footer: ResourceStr = '';
  @BuilderParam rows: () => void = this.Empty;

  @Builder
  Empty() {}

  build() {
    Column({ space: 8 }) {
      if (this.heading !== '') {
        Text(this.heading)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 16, right: 16 })
      }
      Column() {
        this.rows()
      }
      .width('100%')
      .borderRadius(CARD_RADIUS)
      .clip(true)
      .backgroundColor(this.appStyle.palette.cardBackground)
      if (this.footer !== '') {
        Text(this.footer)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
