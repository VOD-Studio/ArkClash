import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';
import { ProxyNodeView } from './ProxyView';

@ComponentV2
export struct ProxyDelay {
  @Param @Require node: ProxyNodeView;
  @Param active: boolean = true;
  @Param textScale: number = 1;
  @Param restriction: ResourceStr = '';
  @Event onTest: () => void = () => {};

  private delayColor(): ResourceColor {
    if (this.node.delay < 0) {
      return $r('app.color.status_error');
    }
    return this.node.delay >= 600 ? $r('app.color.warning') : $r('app.color.status_connected');
  }

  private delayLabel(): ResourceStr {
    if (this.node.phase === 'queued') {
      return $r('app.string.proxy_test_queued');
    }
    if (this.node.phase === 'running') {
      return $r('app.string.proxy_test_running');
    }
    if (this.node.delay === -1) {
      return $r('app.string.proxy_test_timeout');
    }
    if (this.node.delay === -2) {
      return $r('app.string.proxy_test_failed');
    }
    return this.node.delay > 0 ? $r('app.string.proxy_delay_ms', this.node.delay) : $r('app.string.delay_untested');
  }

  private accessibleState(): string {
    const status = uiResourceText(this.getUIContext(), this.delayLabel());
    const restriction = this.restriction !== '' ? this.restriction :
      !this.node.online ? $r('app.string.proxy_test_offline') : '';
    return restriction === '' ? status : `${status}，${uiResourceText(this.getUIContext(), restriction)}`;
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      if (this.node.phase === 'running' && this.active) {
        LoadingProgress()
          .width(13 * this.textScale)
          .height(13 * this.textScale)
          .color($r('app.color.brand'))
          .enableLoading(this.active)
      } else if (this.node.phase !== 'idle') {
        AppGlyph({ name: 'clock', iconSize: 13 * this.textScale, iconColor: $r('sys.color.font_tertiary') })
      } else if (this.node.delay === 0) {
        AppGlyph({ name: 'bolt', iconSize: 13 * this.textScale, iconColor: $r('app.color.brand') })
      } else {
        Text(this.delayLabel())
          .fontSize(11)
          .lineHeight(13)
          .fontWeight(600)
          .fontColor(this.delayColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .height(13 * this.textScale)
    .constraintSize({ minWidth: 13 * this.textScale, maxWidth: 84 })
    .padding(0)
    .borderRadius(4)
    .backgroundColor(Color.Transparent)
    .enabled(this.active && this.node.testable && this.node.phase === 'idle')
    .accessibilityText($r('app.string.proxy_test_node'))
    .accessibilityDescription(this.accessibleState())
    .onClick(() => this.onTest())
    .visibility(this.node.testable || this.node.phase !== 'idle' || this.node.delay !== 0 ?
      Visibility.Visible : Visibility.None)
  }
}
