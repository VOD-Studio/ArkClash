import { AppearanceState, appAppearance } from './AppearanceState';
import { AppGlyph } from './AppGlyph';
import { uiResourceText } from './ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_GAP } from './Theme';

// 自定义标题不继承原生文字标题与返回按钮之间的留白。
const BACK_TITLE_GAP = 12;

@ComponentV2
export struct DestinationTitle {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param titleText: ResourceStr = '';
  @Param selectable: boolean = false;
  @Param actionGlyph: string = 'chevronDown';
  @Event onSelect: () => void = (): void => {};

  @Builder
  TitleText() {
    Text(this.titleText)
      .fontFamily(this.appStyle.fontFamily)
      .fontSize(COMPACT_TITLE_SIZE)
      .lineHeight(COMPACT_TITLE_LINE_HEIGHT)
      .fontWeight(600)
      .fontColor($r('sys.color.font_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .flexShrink(1)
  }

  build() {
    Row() {
      if (this.selectable) {
        Button() {
          Row({ space: HEADER_GAP }) {
            this.TitleText()
            AppGlyph({ name: this.actionGlyph, iconSize: 16 })
          }
        }
        .constraintSize({ maxWidth: '100%' })
        .height('100%')
        .buttonStyle(ButtonStyleMode.NORMAL)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 4, top: 8, bottom: 8 })
        .accessibilityText(uiResourceText(this.getUIContext(), this.titleText))
        .onClick((): void => { this.onSelect(); })
      } else {
        this.TitleText()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: BACK_TITLE_GAP, right: HEADER_GAP })
    .alignItems(VerticalAlign.Center)
  }
}
