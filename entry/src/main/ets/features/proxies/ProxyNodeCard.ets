import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';
import { ProxyDelay } from './ProxyDelay';
import { ProxyDensity } from './ProxyLogic';
import { proxyCardHeight, proxyTextScale } from './ProxyMetrics';
import { ProxyNodeView } from './ProxyView';
import { ProxyPressFeedback, ProxyPressState } from './ProxyPressFeedback';

@ReusableV2
@ComponentV2
export struct ProxyNodeCard {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require node: ProxyNodeView;
  @Param cardType: ProxyDensity = 'standard';
  @Param active: boolean = true;
  @Param motionEnabled: boolean = false;
  @Param nestedSurface: boolean = false;
  @Param groupType: string = '';
  @Local textScale: number = 1;
  private press: ProxyPressState = new ProxyPressState();
  @Event onChoose: () => void = () => {};
  @Event onTest: () => void = () => {};

  aboutToAppear(): void {
    this.textScale = proxyTextScale(this.getUIContext());
  }

  aboutToDisappear(): void {
    this.press.reset();
  }

  aboutToRecycle(): void {
    this.press.recycle();
  }

  aboutToReuse(): void {
    this.press.reset();
  }

  @Monitor('node', 'active', 'motionEnabled')
  resetPress(): void {
    this.press.reset();
  }

  private restriction(): ResourceStr {
    if (!this.node.addressable) {
      return $r('app.string.proxy_node_not_addressable');
    }
    if (this.node.leafRetired) {
      return $r('app.string.proxy_actual_retired');
    }
    return this.node.unresolved ? $r('app.string.proxy_leaf_unresolved') : '';
  }

  private description(): ResourceStr {
    if (this.node.type === '') {
      return $r('app.string.proxy_type_unknown');
    }
    return this.cardType === 'loose' && this.node.nested && !this.node.unresolved && !this.node.leafRetired &&
      this.node.leafName !== '' && this.node.leafName !== this.node.name ?
      `${this.node.type}(${this.node.leafName})` : this.node.type;
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

  private accessibleState(): string {
    const state = uiResourceText(this.getUIContext(), this.selectionLabel());
    const restriction = this.restriction();
    return restriction === '' ? state : `${state}，${uiResourceText(this.getUIContext(), restriction)}`;
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
        MenuItem({ content: this.restriction() })
          .enabled(false)
      }
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Button({ type: ButtonType.Normal }) {
        ProxyPressFeedback({ feedback: this.press })
      }
        .width('100%')
        .height('100%')
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(20)
        .clip(true)
        .stateEffect(!this.motionEnabled)
        .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
          this.press.resize(Number(after.width), Number(after.height));
        })
        .onTouch((event: TouchEvent): void => this.press.touch(event, this.getUIContext(), this.motionEnabled))
        .accessibilityText(this.node.name)
        .accessibilityDescription(this.accessibleState())
        .accessibilitySelected(this.node.selected || this.node.pinned)
        .enabled(this.active && this.node.selectable)
        .onClick(() => this.onChoose())
      Column() {
        Row({ space: 4 }) {
          Text(this.node.name)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(FontWeight.Normal)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(this.cardType === 'compact' ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .align(Alignment.TopStart)
            .layoutWeight(1)
            .hitTestBehavior(HitTestMode.None)
          if (this.node.pending || this.node.pinned || this.node.selected) {
            Stack() {
              if (this.node.pending && this.active) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(this.appStyle.palette.onBrand)
                  .enableLoading(this.active)
                  .hitTestBehavior(HitTestMode.None)
              } else {
                AppGlyph({ name: this.node.pinned ? 'pin' : 'check', iconSize: 16,
                  iconColor: this.node.pinned && !this.node.selected ? this.appStyle.palette.brand : this.appStyle.palette.onBrand })
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .width(22)
            .height(22)
            .borderRadius(11)
            .backgroundColor(this.node.pinned && !this.node.selected ? this.appStyle.palette.selectionTonal : this.appStyle.palette.brand)
            .hitTestBehavior(HitTestMode.None)
            .transition(this.active && this.motionEnabled ? TransitionEffect.OPACITY : TransitionEffect.IDENTITY)
          }
        }
        .width('100%')
        .height((this.cardType === 'compact' ? 20 : 40) * this.textScale)
        .alignItems(VerticalAlign.Top)
        .hitTestBehavior(HitTestMode.None)
        Row({ space: 8 }) {
          Text(this.description())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor(this.node.leafRetired ? $r('app.color.warning') : $r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .hitTestBehavior(HitTestMode.None)
          Row() {
            ProxyDelay({ node: this.node, active: this.active, textScale: this.textScale,
              restriction: this.restriction(), onTest: () => this.onTest() })
          }
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
        }
        .height(18 * this.textScale)
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(proxyCardHeight(this.cardType, this.textScale))
    .borderRadius(20)
    .border({ width: this.node.located ? 2 : 0, color: this.appStyle.palette.brand })
    .backgroundColor(this.nestedSurface ? this.appStyle.palette.proxyNodeBackground : this.appStyle.palette.cardBackground)
    .animation({ duration: this.active && this.motionEnabled ? 160 : 0, curve: Curve.EaseOut })
    .bindContextMenu(this.nodeMenu, ResponseType.LongPress)
  }
}
