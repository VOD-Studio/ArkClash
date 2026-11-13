import { ProxyBrowser } from './Proxies';

@ComponentV2
export struct ProxyFeedback {
  @Param @Require browser: ProxyBrowser;

  private noticeLabel(): ResourceStr {
    switch (this.browser.notice) {
      case 'offline': return $r('app.string.proxy_test_offline');
      case 'unresolved': return $r('app.string.proxy_leaf_unresolved');
      case 'unsupported': return $r('app.string.proxy_group_unselectable');
      case 'notAddressable': return $r('app.string.proxy_node_not_addressable');
      case 'hostUnknown': return $r('app.string.proxy_host_unknown');
      case 'capacity': return $r('app.string.proxy_test_capacity');
      case 'noConclusion': return $r('app.string.proxy_test_no_conclusion');
      case 'cleanupFailed': return $r('app.string.proxy_cleanup_failed');
      case 'inconsistent': return $r('app.string.proxy_selection_inconsistent');
      case 'selectionFailed': return $r('app.string.proxy_selection_failed');
      case 'filtered': return $r('app.string.proxy_locate_filtered');
      default: return $r('app.string.proxy_not_ready');
    }
  }

  build() {
    Column({ space: 8 }) {
      if (this.browser.loadError) {
        Row({ space: 8 }) {
          Text(this.browser.stale ? $r('app.string.proxy_stale') : $r('app.string.proxy_load_failed'))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .layoutWeight(1)
          Button($r('app.string.proxy_retry'))
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .backgroundColor(Color.Transparent)
            .onClick(() => this.browser.refresh())
        }
        .width('100%')
        .padding(8)
        .borderRadius(12)
        .backgroundColor($r('app.color.error_soft'))
      }
      if (this.browser.preferenceError) {
        Row({ space: 8 }) {
          Text($r('app.string.proxy_preferences_failed'))
            .fontSize(13)
            .fontColor($r('app.color.warning'))
            .layoutWeight(1)
          Button($r('app.string.proxy_retry'))
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .backgroundColor(Color.Transparent)
            .onClick(() => this.browser.retryPreferences())
        }
        .width('100%')
        .padding(8)
        .borderRadius(12)
        .backgroundColor($r('app.color.warning_soft'))
      }
      if (!this.browser.online && this.browser.totalGroups > 0 && !this.browser.loadError) {
        Text(this.browser.offlineWritable ? $r('app.string.proxy_offline_saved') : $r('app.string.proxy_host_unknown'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      if (this.browser.notice !== '') {
        Row({ space: 8 }) {
          Text(this.noticeLabel())
            .fontSize(13)
            .fontColor($r('app.color.warning'))
            .layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([$r('sys.color.font_secondary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.proxy_dismiss'))
          .onClick(() => { this.browser.notice = ''; })
        }
        .width('100%')
        .padding(8)
        .borderRadius(12)
        .backgroundColor($r('app.color.warning_soft'))
      }
    }
    .width('100%')
  }
}
