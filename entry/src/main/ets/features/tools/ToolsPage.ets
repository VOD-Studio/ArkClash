import { ListRow } from '../../components/ListRow';
import { TabPage } from '../../components/TabPage';
import { CARD_RADIUS } from '../../components/Theme';
import { ToolRoute } from './ToolRoutes';

@ComponentV2
export struct ToolsPage {
  @Param @Require scroller: Scroller;
  @Param topInset: number = 0;
  @Event onOpen: (route: ToolRoute) => void = () => {};

  build() {
    TabPage({ title: $r('app.string.tab_tools'), topInset: this.topInset, scroller: this.scroller }) {
      this.Group([
        new Entry(ToolRoute.Connections, $r('sys.symbol.list_bullet'), $r('app.string.tools_connections')),
        new Entry(ToolRoute.Logs, $r('sys.symbol.doc_plaintext'), $r('app.string.tools_logs'))
      ])
      this.Group([
        new Entry(ToolRoute.Settings, $r('sys.symbol.gearshape'), $r('app.string.tools_settings')),
        new Entry(ToolRoute.About, $r('sys.symbol.info_circle'), $r('app.string.tools_about'))
      ])
    }
  }

  @Builder
  Group(entries: Entry[]) {
    Column() {
      ForEach(entries, (entry: Entry, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 50, right: 16 })
        }
        ListRow({ icon: entry.icon, title: entry.title, onTap: () => this.onOpen(entry.route) })
      }, (entry: Entry) => entry.route)
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .clip(true)
    .backgroundColor($r('app.color.card_background'))
  }
}

class Entry {
  route: ToolRoute;
  icon: Resource;
  title: Resource;

  constructor(route: ToolRoute, icon: Resource, title: Resource) {
    this.route = route;
    this.icon = icon;
    this.title = title;
  }
}
