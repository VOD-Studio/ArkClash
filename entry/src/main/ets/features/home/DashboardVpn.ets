import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { connection, Connection } from '../../client/Connection';
import { LabeledValue } from '../../components/Labels';
import { DASHBOARD_CARD, PAGE_GUTTER } from '../../components/Theme';
import { AppGlyph } from '../../components/AppGlyph';
import { DASHBOARD_COOKIE6 } from './DashboardShapePaths';

@ComponentV2
export struct DashboardVpn {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;
  @Local details: boolean = false;

  @Monitor('visible')
  sync(): void {
    if (!this.visible) { this.details = false; }
  }

  @Builder
  Details() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.conn.sessionMode === 'tun' ? $r('app.string.dash_vpn_mode_tun') :
          $r('app.string.dash_vpn_mode_proxy'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17)
          .lineHeight(22)
          .fontWeight(600)
          .width('100%')
          .padding({ left: 5, right: 5, top: 8 })
        Column({ space: 16 }) {
          LabeledValue({ label: $r('app.string.dash_vpn_listeners'), value: this.conn.listenersOpen ?
            $r('app.string.dash_vpn_open') : $r('app.string.dash_vpn_closed') })
            .width('100%')
          LabeledValue({ label: $r('app.string.dash_vpn_tun'), value: this.conn.tunAttached ?
            $r('app.string.dash_vpn_attached') : $r('app.string.dash_vpn_detached') })
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(22)
        .backgroundColor(this.appStyle.palette.tileBackground)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Row({ space: 14 }) {
        Stack() {
          if (this.conn.tunAttached) {
            Shape() {
              Path().commands(DASHBOARD_COOKIE6).fill(this.appStyle.palette.brand).strokeWidth(0)
            }
            .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
            .width(48)
            .height(48)
          } else {
            Circle({ width: 48, height: 48 }).fill(this.appStyle.palette.tileBackground).strokeWidth(0)
          }
          AppGlyph({ name: 'vpn', iconSize: 22,
            iconColor: this.conn.tunAttached ? Color.White : $r('sys.color.font_secondary') })
        }
        .width(48)
        .height(48)
        Column() {
          Text($r('app.string.dash_vpn'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .lineHeight(21)
            .fontWeight(600)
          Text(this.conn.tunAttached ? $r('app.string.dash_vpn_attached') : $r('app.string.dash_vpn_detached'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.conn.tunAttached })
          .enabled(false)
          .accessibilityText($r('app.string.dash_vpn'))
          .accessibilityDescription($r('app.string.dash_vpn_capability'))
      }
      .width('100%')
    }
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .onClick((): void => { if (this.interactive) { this.details = true; } })
    .bindSheet($$this.details, this.Details, {
      title: { title: $r('app.string.dash_vpn') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: this.appStyle.sheetMaterial(), showClose: true
    })
  }
}
