import { EmptyState } from '../../components/EmptyState';
import { FLOATING_BAR_INSET, PAGE_GUTTER } from '../../components/Theme';
import { ProxyNodeLine } from './ProxyNodeLine';
import { ProxyGroupView, ProxyNodeRow } from './ProxyView';

@ComponentV2
export struct ProxyTabGrid {
  @Param @Require group: ProxyGroupView;
  @Param @Require scroller: Scroller;
  @Param active: boolean = false;
  @Event onChoose: (node: string) => void = () => {};
  @Event onTest: (node: string) => void = () => {};
  @Event onListScroll: (offset: number, source: ScrollSource) => void = () => {};

  build() {
    List({ scroller: this.scroller }) {
      if (this.group.rows.totalCount() === 0) {
        ListItem() {
          EmptyState({
            title: $r('app.string.proxy_group_empty'),
            hint: this.group.dynamic ? $r('app.string.proxy_dynamic_offline') : $r('app.string.proxy_group_empty_hint')
          })
        }
      } else {
        LazyForEach(this.group.rows, (row: ProxyNodeRow) => {
          ListItem() {
            ProxyNodeLine({
              row: row,
              cardType: this.group.cardType,
              active: this.active,
              onChoose: (node: string) => this.onChoose(node),
              onTest: (node: string) => this.onTest(node)
            })
          }
        }, (row: ProxyNodeRow): string => row.key)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
    .contentEndOffset(FLOATING_BAR_INSET)
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => this.onListScroll(offset, source))
  }
}
