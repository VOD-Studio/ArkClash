import { EmptyState } from '../../components/EmptyState';
import { FLOATING_BAR_INSET, PAGE_GUTTER } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { ProxyGroupHeader } from './ProxyGroupHeader';
import { ProxyNodeLine } from './ProxyNodeLine';
import { ProxyGroupView, ProxyNodeRow } from './ProxyView';

interface ProxyHeaderBinding {
  group: ProxyGroupView;
}

@ComponentV2
export struct ProxyGroupList {
  @Param @Require browser: ProxyBrowser;
  @Param @Require scroller: Scroller;
  @Param active: boolean = false;
  @Param pickerMode: boolean = false;
  @Event onLocate: (group: string) => void = () => {};
  @Event onListScroll: (offset: number, source: ScrollSource) => void = () => {};

  @Builder
  private groupHeader($$: ProxyHeaderBinding) {
    ProxyGroupHeader({
      group: $$.group,
      online: this.browser.online,
      offlineWritable: this.browser.offlineWritable,
      showLocate: !this.pickerMode,
      collapsible: !this.pickerMode,
      onToggle: () => this.browser.toggleGroup($$.group.name),
      onLocate: () => this.onLocate($$.group.name),
      onTest: () => this.browser.test($$.group.name),
      onClearPin: () => this.browser.clearPin($$.group.name)
    })
  }

  build() {
    List({ scroller: this.scroller, space: 8 }) {
      LazyForEach(this.browser.source, (group: ProxyGroupView) => {
        ListItemGroup({ header: () => { this.groupHeader({ group: group }); } }) {
          if (group.expanded && group.nodes.length === 0) {
            ListItem() {
              EmptyState({
                title: $r('app.string.proxy_group_empty'),
                hint: group.dynamic ? $r('app.string.proxy_dynamic_offline') : $r('app.string.proxy_group_empty_hint')
              })
            }
          } else {
            LazyForEach(group.rows, (row: ProxyNodeRow) => {
              ListItem() {
                ProxyNodeLine({
                  row: row,
                  cardType: group.cardType,
                  active: this.active,
                  onChoose: (node: string) => this.browser.choose(group.name, node),
                  onTest: (node: string) => this.browser.test(group.name, node)
                })
              }
            }, (row: ProxyNodeRow): string => row.key)
          }
        }
      }, (group: ProxyGroupView): string => group.key)
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
    .contentEndOffset(FLOATING_BAR_INSET)
    .cachedCount(2)
    .sticky(StickyStyle.Header)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => this.onListScroll(offset, source))
  }
}
