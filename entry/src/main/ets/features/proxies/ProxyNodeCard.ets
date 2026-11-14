import { SymbolGlyphModifier } from '@kit.ArkUI';
import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';
import { ProxyDelay } from './ProxyDelay';
import { ProxyDensity } from './ProxyLogic';
import { proxyCardHeight, proxyTextScale } from './ProxyMetrics';
import { ProxyNodeView } from './ProxyView';

@ReusableV2
@ComponentV2
export struct ProxyNodeCard {
  @Param @Require node: ProxyNodeView;
  @Param cardType: ProxyDensity = 'standard';
  @Param active: boolean = true;
  @Param nestedSurface: boolean = false;
  @Param groupType: string = '';
  @Local textScale: number = 1;
  @Event onChoose: () => void = () => {};
  @Event onTest: () => void = () => {};

  aboutToAppear(): void {
    this.textScale = proxyTextScale(this.getUIContext());
  }

  private description(): ResourceStr {
    if (!this.node.addressable) {
      return $r('app.string.proxy_node_not_addressable');
    }
    if (this.node.leafRetired) {
      return $r('app.string.proxy_actual_retired');
    }
    if (this.cardType === 'loose' && this.node.nested) {
      return this.node.unresolved ? $r('app.string.proxy_leaf_unresolved') : `${this.node.type}(${this.node.leafName})`;
    }
    return this.node.type === '' ? $r('app.string.proxy_type_unknown') : this.node.type;
  }

  private selectionLabel(): ResourceStr {
    if (this.node.pending) {
      return $r('app.string.proxy_selection_pending');
    }
    if (this.node.pinned) {
      return $r('app.string.proxy_pinned');
    }
    return this.node.selected ? this.node.online ? $r('app.string.proxy_actual') : $r('app.string.proxy_selected') :
      $r('app.string.proxy_choose_node');
  }

  @Builder
  private nodeMenu() {
    Menu() {
      if (this.groupType === 'Selector' || this.groupType === 'URLTest' || this.groupType === 'Fallback') {
        MenuItem({
          content: this.groupType === 'Selector' ? $r('app.string.proxy_select') : $r('app.string.proxy_preferred'),
          symbolStartIcon: new SymbolGlyphModifier(this.groupType === 'Selector' ? $r('sys.symbol.checkmark') : $r('sys.symbol.pin'))
        })
          .selected(this.groupType === 'Selector' ? this.node.selected : this.node.pinned)
          .selectIcon(true)
          .enabled(this.active && this.node.selectable)
          .onClick(() => this.onChoose())
      }
      if (!this.node.addressable || this.node.leafRetired || this.node.unresolved) {
        MenuItem({ content: this.description() })
          .enabled(false)
      }
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Button({ type: ButtonType.Normal }) {
        Column() {
          Row({ space: 4 }) {
            Text(this.node.name)
              .fontSize(15)
              .lineHeight(20)
              .fontWeight(FontWeight.Normal)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(this.cardType === 'compact' ? 1 : 2)
              .height((this.cardType === 'compact' ? 20 : 40) * this.textScale)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .align(Alignment.TopStart)
              .layoutWeight(1)
            if (this.node.pending || this.node.pinned || this.node.selected) {
              Stack() {
                if (this.node.pending && this.active) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color($r('app.color.on_brand'))
                    .enableLoading(this.active)
                } else {
                  AppGlyph({
                    name: this.node.pinned ? 'pin' : 'check', iconSize: 16,
                    iconColor: this.node.pinned && !this.node.selected ? $r('app.color.brand') : $r('app.color.on_brand')
                  })
                }
              }
              .width(22)
              .height(22)
              .borderRadius(11)
              .backgroundColor(this.node.pinned && !this.node.selected ? $r('app.color.selection_tonal') : $r('app.color.brand'))
              .accessibilityText(uiResourceText(this.getUIContext(), this.selectionLabel()))
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          Row() {
            Text(this.description())
              .fontSize(13)
              .lineHeight(18)
              .fontColor(this.node.leafRetired ? $r('app.color.warning') : $r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.cardType !== 'loose') {
              Blank()
                .width(50)
            }
          }
          .height(18 * this.textScale)
          .width('100%')
          .margin({ top: 8 })
          if (this.cardType === 'loose') {
            Blank()
              .height(13 * this.textScale)
              .margin({ top: 6 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(proxyCardHeight(this.cardType, this.textScale))
      .padding({ left: 12, right: 12 })
      .backgroundColor(Color.Transparent)
      .borderRadius(20)
      .accessibilityText(this.node.name)
      .accessibilityDescription(uiResourceText(this.getUIContext(), this.selectionLabel()))
      .accessibilitySelected(this.node.selected || this.node.pinned)
      .enabled(this.active && this.node.selectable)
      .onClick(() => this.onChoose())
      ProxyDelay({ node: this.node, active: this.active, textScale: this.textScale, onTest: () => this.onTest() })
        .align(this.cardType === 'loose' ? Alignment.BottomStart : Alignment.BottomEnd)
        .margin({ left: 12, right: 12, bottom: 12 })
    }
    .width('100%')
    .height(proxyCardHeight(this.cardType, this.textScale))
    .borderRadius(20)
    .backgroundColor(this.nestedSurface ? $r('app.color.surface_block') : $r('app.color.card_background'))
    .bindContextMenu(this.nodeMenu, ResponseType.LongPress)
  }
}
