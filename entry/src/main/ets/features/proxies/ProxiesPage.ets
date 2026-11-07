import { EmptyState } from '../../components/EmptyState';
import { TabPage } from '../../components/TabPage';
import { CARD } from '../../components/Theme';

// 代理组页由 #22 实现，这里先占住导航里的位置。
@ComponentV2
export struct ProxiesPage {
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Param topInset: number = 0;

  build() {
    TabPage({
      title: $r('app.string.tab_proxies'),
      topInset: this.topInset,
      scroller: this.scroller,
      onScrollDirection: (down: boolean) => this.onScrollDirection(down)
    }) {
      Column() {
        EmptyState({
          icon: $r('sys.symbol.paperplane'),
          title: $r('app.string.proxies_empty'),
          hint: $r('app.string.proxies_empty_hint')
        })
      }
      .attributeModifier(CARD)
    }
  }
}
