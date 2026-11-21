import { ProxyNodeCard } from './ProxyNodeCard';
import { ProxyDensity } from './ProxyLogic';
import { ProxyNodeRow, ProxyNodeView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyNodeLine {
  @Param @Require row: ProxyNodeRow;
  @Param cardType: ProxyDensity = 'standard';
  @Param active: boolean = true;
  @Param motionEnabled: boolean = false;
  @Param nestedSurface: boolean = false;
  @Param groupType: string = '';
  @Event onChoose: (node: string) => void = () => {};
  @Event onTest: (node: string) => void = () => {};
  @Event onSaveToLibrary: (node: string) => void = () => {};

  build() {
    Row({ space: 8 }) {
      ForEach(this.row.nodes, (node: ProxyNodeView) => {
        ProxyNodeCard({
          node: node,
          cardType: this.cardType,
          active: this.active,
          motionEnabled: this.motionEnabled,
          nestedSurface: this.nestedSurface,
          groupType: this.groupType,
          onChoose: () => this.onChoose(node.id),
          onTest: () => this.onTest(node.id),
          onSaveToLibrary: () => this.onSaveToLibrary(node.id)
        })
          .layoutWeight(1)
      }, (node: ProxyNodeView): string => node.key)
      ForEach(this.row.blanks, (blank: string) => {
        Blank()
          .layoutWeight(1)
      }, (blank: string): string => blank)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ bottom: 8 })
  }
}
