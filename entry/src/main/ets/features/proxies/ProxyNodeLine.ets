import { ProxyNodeCard } from './ProxyNodeCard';
import { ProxyDensity } from './ProxyLogic';
import { ProxyNodeRow, ProxyNodeView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyNodeLine {
  @Param @Require row: ProxyNodeRow;
  @Param cardType: ProxyDensity = 'standard';
  @Param active: boolean = true;
  @Param nestedSurface: boolean = false;
  @Param groupType: string = '';
  @Event onChoose: (node: string) => void = () => {};
  @Event onTest: (node: string) => void = () => {};

  build() {
    Row({ space: 8 }) {
      ForEach(this.row.nodes, (node: ProxyNodeView) => {
        ProxyNodeCard({
          node: node,
          cardType: this.cardType,
          active: this.active,
          nestedSurface: this.nestedSurface,
          groupType: this.groupType,
          onChoose: () => this.onChoose(node.id),
          onTest: () => this.onTest(node.id)
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
