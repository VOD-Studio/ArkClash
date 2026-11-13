import { ProxyBrowser } from './Proxies';
import { ProxyGroupView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyGroupJumpItem {
  @Param @Require browser: ProxyBrowser;
  @Param @Require group: ProxyGroupView;
  @Param rowExtent: number = 48;
  @Event onChoose: (groupName: string) => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        if (this.browser.currentGroup === this.group.name) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(16)
            .fontColor([$r('app.color.brand')])
            .width(20)
        } else {
          Blank()
            .width(20)
        }
        Text(this.group.name)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .constraintSize({ minHeight: this.rowExtent })
    .borderRadius(8)
    .backgroundColor(Color.Transparent)
    .accessibilityText(this.group.name)
    .accessibilitySelected(this.browser.currentGroup === this.group.name)
    .onClick(() => this.onChoose(this.group.name))
  }
}
