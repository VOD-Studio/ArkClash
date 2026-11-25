import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { PAGE_GUTTER } from '../../components/Theme';
import { SettingsSection } from './SettingsSection';
import { ToolRoute } from './ToolRoutes';

@ComponentV2
export struct AdvancedConfigPage {
  @Param @Require topInset: number;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onOpen: (route: ToolRoute) => void = () => {};

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.tools_advanced_config') })
  }

  @Builder
  Entries() {
    ListRow({
      icon: $r('sys.symbol.connection'),
      title: $r('app.string.network_title'),
      onTap: (): void => this.onOpen(ToolRoute.Network)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.square_stack_3d'),
      title: 'DNS',
      onTap: (): void => this.onOpen(ToolRoute.DnsOverrides)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.list_bullet'),
      title: $r('app.string.added_rules_title'),
      onTap: (): void => this.onOpen(ToolRoute.AddedRules)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.doc_text'),
      title: $r('app.string.script_title'),
      onTap: (): void => this.onOpen(ToolRoute.Scripts)
    })
  }

  @Builder
  CustomResources() {
    ListRow({
      icon: $r('sys.symbol.connection'),
      title: $r('app.string.local_proxy_title'),
      onTap: (): void => this.onOpen(ToolRoute.LocalProxies)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.list_bullet'),
      title: $r('app.string.rule_set_title'),
      onTap: (): void => this.onOpen(ToolRoute.RuleSets)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.line_3_horizontal'),
      title: $r('app.string.proxy_filters_title'),
      onTap: (): void => this.onOpen(ToolRoute.ProxyFilters)
    })
    Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
    ListRow({
      icon: $r('sys.symbol.picture'),
      title: $r('app.string.icon_sets_title'),
      onTap: (): void => this.onOpen(ToolRoute.IconSets)
    })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          SettingsSection({ rows: (): void => this.Entries() })
          SettingsSection({ heading: $r('app.string.local_proxy_resources'),
            rows: (): void => this.CustomResources() })
        }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }
}
