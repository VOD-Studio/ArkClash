import { Delay } from '../../components/Delay';
import { ProxyDensity } from './ProxyLogic';
import { ProxyNodeView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyNodeCard {
  @Param @Require node: ProxyNodeView;
  @Param cardType: ProxyDensity = 'standard';
  @Param active: boolean = true;
  @Event onChoose: () => void = () => {};
  @Event onTest: () => void = () => {};

  private cardColor(): ResourceColor {
    return this.node.pending || this.node.selected || this.node.pinned ?
      $r('app.color.brand_soft') : $r('app.color.card_background');
  }

  private selectionLabel(): Resource {
    if (this.node.pending) {
      return $r('app.string.proxy_selection_pending');
    }
    if (this.node.pinned) {
      return $r('app.string.proxy_pinned');
    }
    return this.node.selected ? this.node.online ? $r('app.string.proxy_actual') : $r('app.string.proxy_selected') :
      $r('app.string.proxy_choose_node');
  }

  build() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          Text(this.node.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(this.cardType === 'compact' ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 4 }) {
            if (this.node.selected) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor([$r('app.color.brand')])
                .accessibilityText(this.node.online ? $r('app.string.proxy_actual') : $r('app.string.proxy_selected'))
            }
            if (this.node.pinned) {
              SymbolGlyph($r('sys.symbol.pin'))
                .fontSize(12)
                .fontColor([$r('app.color.brand')])
                .accessibilityText($r('app.string.proxy_pinned'))
            }
            Text(this.node.type === '' ? $r('app.string.proxy_type_unknown') : this.node.type)
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          if (!this.node.addressable) {
            Text($r('app.string.proxy_node_not_addressable'))
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(2)
              .width('100%')
          }
          if (this.node.nested && (this.cardType === 'loose' || this.node.leafRetired)) {
            Text(this.node.unresolved ? $r('app.string.proxy_leaf_unresolved') : this.node.leafName)
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          if (this.node.leafRetired) {
            Text($r('app.string.proxy_actual_retired'))
              .fontSize(11)
              .fontColor($r('app.color.warning'))
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .constraintSize({ minWidth: 0, minHeight: this.cardType === 'compact' ? 68 : 84 })
      .padding({ left: 12, right: 0, top: 12, bottom: 12 })
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.node.name)
      .accessibilityDescription(this.selectionLabel())
      .accessibilitySelected(this.node.selected || this.node.pinned)
      .enabled(this.node.selectable)
      .onClick(() => this.onChoose())
      Delay({
        delayValue: this.node.delay,
        stage: this.node.phase,
        canTest: this.node.testable,
        active: this.active,
        onTest: () => this.onTest()
      })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .border({
      width: 1,
      color: this.node.pending || this.node.selected || this.node.pinned ? $r('app.color.brand') : $r('app.color.divider')
    })
    .alignItems(VerticalAlign.Center)
  }
}
