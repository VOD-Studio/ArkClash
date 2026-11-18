import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyGroupJumpItem {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require browser: ProxyBrowser;
  @Param @Require group: ProxyGroupView;
  @Param rowExtent: number = 44;
  @Event onChoose: (groupName: string) => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Text(this.group.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .lineHeight(20)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.browser.currentGroup === this.group.name) {
          AppGlyph({ name: 'check', iconSize: 16 })
            .width(16)
        }
      }
      .width('100%')
      .padding({ left: 12, right: this.browser.currentGroup === this.group.name ? 8 : 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .height(this.rowExtent)
    .padding(0)
    .borderRadius(16)
    .backgroundColor(Color.Transparent)
    .accessibilityText(this.group.name)
    .accessibilitySelected(this.browser.currentGroup === this.group.name)
    .onClick(() => this.onChoose(this.group.name))
  }
}
