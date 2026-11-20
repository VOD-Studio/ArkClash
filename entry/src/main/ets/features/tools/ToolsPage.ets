import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListRow } from '../../components/ListRow';
import { TabPage } from '../../components/TabPage';
import { SettingsSection } from './SettingsSection';
import { ToolRoute } from './ToolRoutes';

@ComponentV2
export struct ToolsPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require scroller: Scroller;
  @Event onScrollDirection: (down: boolean) => void = () => {};
  @Param topInset: number = 0;
  @Event onOpen: (route: ToolRoute) => void = () => {};

  @Builder
  Content() {
    SettingsSection({ rows: (): void => this.Rows([
      new Entry(ToolRoute.Connections, $r('sys.symbol.list_bullet'), $r('app.string.tools_connections')),
      new Entry(ToolRoute.Dns, $r('sys.symbol.connection'), $r('app.string.tools_dns')),
      new Entry(ToolRoute.Resources, $r('sys.symbol.square_stack_3d'), $r('app.string.tools_resources')),
      new Entry(ToolRoute.Logs, $r('sys.symbol.doc_text'), $r('app.string.tools_logs'))
    ]) })
    SettingsSection({ heading: $r('app.string.tools_settings'), rows: (): void => this.Rows([
      new Entry(ToolRoute.General, $r('sys.symbol.slider_horizontal_2'), $r('app.string.tools_general')),
      new Entry(ToolRoute.Theme, $r('sys.symbol.slider_horizontal_2'), $r('app.string.tools_theme')),
      new Entry(ToolRoute.AdvancedConfig, $r('sys.symbol.wrench_and_screwdriver'), $r('app.string.tools_advanced_config'))
    ]) })
    SettingsSection({ heading: $r('app.string.tools_other'), rows: (): void => this.Rows([
      new Entry(ToolRoute.About, $r('sys.symbol.info_circle'), $r('app.string.tools_about'))
    ]) })
  }

  build() {
    TabPage({
      title: $r('app.string.tab_tools'),
      topInset: this.topInset,
      scroller: this.scroller,
      onScrollDirection: (down: boolean) => this.onScrollDirection(down),
      content: (): void => this.Content()
    })
  }

  @Builder
  Rows(entries: Entry[]) {
    ForEach(entries, (entry: Entry, index: number) => {
      if (index > 0) {
        Divider()
          .color(this.appStyle.palette.divider)
          .margin({ left: 50, right: 16 })
      }
      ListRow({ icon: entry.icon, title: entry.title, onTap: () => this.onOpen(entry.route) })
    }, (entry: Entry) => entry.route)
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
