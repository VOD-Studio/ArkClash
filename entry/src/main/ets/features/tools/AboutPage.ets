import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { bundleManager, common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { CARD_RADIUS, PAGE_GUTTER } from '../../components/Theme';

const SOURCE_URL = 'https://github.com/VOD-Studio/ArkClash';

@ComponentV2
export struct AboutPage {
  @Param @Require topInset: number;
  @Local private appStyle: AppearanceState = appAppearance;

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.tools_about') })
  }

  build() {
    NavDestination() {
      AboutContent()
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }
}

@ComponentV2
struct AboutContent {
  @Local private appStyle: AppearanceState = appAppearance;
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
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .margin({ bottom: 24 })
      Column() {
        ListRow({ title: $r('app.string.about_version'), value: this.version, chevron: false })
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
        ListRow({
          title: $r('app.string.about_core'),
          value: this.conn.coreVersion !== '' ? `mihomo ${this.conn.coreVersion}` : $r('app.string.about_core_idle'),
          chevron: false
        })
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
        ListRow({ title: $r('app.string.about_license'), value: 'GPL-3.0', chevron: false })
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
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
      .backgroundColor(this.appStyle.palette.cardBackground)
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }
}
