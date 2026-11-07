import { bundleManager, common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { connection, Connection } from '../../client/Connection';
import { EmptyState } from '../../components/EmptyState';
import { ListRow } from '../../components/ListRow';
import { CARD_RADIUS, PAGE_GUTTER } from '../../components/Theme';
import { ToolRoute } from './ToolRoutes';

const SOURCE_URL = 'https://github.com/VOD-Studio/ArkClash';

function titleOf(route: string): Resource {
  switch (route) {
    case ToolRoute.Connections:
      return $r('app.string.tools_connections');
    case ToolRoute.Logs:
      return $r('app.string.tools_logs');
    case ToolRoute.Settings:
      return $r('app.string.tools_settings');
    default:
      return $r('app.string.tools_about');
  }
}

function titleOptions(): NavigationTitleOptions {
  return {
    systemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR })
  };
}

/** 工具页的二级页面，由页面层的 navDestination 按路由名创建。 */
@ComponentV2
export struct ToolPage {
  @Param route: string = ToolRoute.About;

  build() {
    NavDestination() {
      if (this.route === ToolRoute.About) {
        AboutContent()
      } else {
        EmptyState({
          icon: $r('sys.symbol.wrench_and_screwdriver'),
          title: $r('app.string.coming_soon'),
          hint: $r('app.string.coming_soon_hint')
        })
      }
    }
    .title(titleOf(this.route), titleOptions())
    .backgroundColor($r('app.color.page_background'))
  }
}

@ComponentV2
struct AboutContent {
  @Local conn: Connection = connection;
  private version: string =
    bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  build() {
    Column() {
      Image($r('app.media.startIcon'))
        .width(88)
        .height(88)
        .borderRadius(20)
        .margin({ top: 24, bottom: 12 })
      Text($r('app.string.app_title'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .margin({ bottom: 24 })
      Column() {
        ListRow({ title: $r('app.string.about_version'), value: this.version, chevron: false })
        Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
        ListRow({
          title: $r('app.string.about_core'),
          value: this.conn.coreVersion !== '' ? `mihomo ${this.conn.coreVersion}` : $r('app.string.about_core_idle'),
          chevron: false
        })
        Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
        ListRow({ title: $r('app.string.about_license'), value: 'GPL-3.0', chevron: false })
        Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
        ListRow({
          title: $r('app.string.about_source'),
          value: 'GitHub',
          onTap: () => {
            this.context.openLink(SOURCE_URL).catch(() => {});
          }
        })
      }
      .width('100%')
      .borderRadius(CARD_RADIUS)
      .clip(true)
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }
}
