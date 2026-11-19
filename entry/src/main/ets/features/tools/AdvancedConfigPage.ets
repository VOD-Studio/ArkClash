import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { PAGE_GUTTER } from '../../components/Theme';
import { SettingsSection } from './SettingsSection';
import { ToolRoute } from './ToolRoutes';

@ComponentV2
export struct AdvancedConfigPage {
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
  }

  build() {
    NavDestination() {
      Scroll() {
        SettingsSection({ rows: (): void => this.Entries() })
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }
}
