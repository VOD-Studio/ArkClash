import { connection, Connection } from '../../client/Connection';
import { LabeledValue } from '../../components/Labels';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardVpn {
  @Local conn: Connection = connection;

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.dash_vpn'), symbol: $r('sys.symbol.checkmark_shield') })
      Text(this.conn.sessionMode === 'tun' ? $r('app.string.dash_vpn_mode_tun') :
        $r('app.string.dash_vpn_mode_proxy'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      Row({ space: 12 }) {
        LabeledValue({ label: $r('app.string.dash_vpn_listeners'), value: this.conn.listenersOpen ?
          $r('app.string.dash_vpn_open') : $r('app.string.dash_vpn_closed') }).layoutWeight(1)
        LabeledValue({ label: $r('app.string.dash_vpn_tun'), value: this.conn.tunAttached ?
          $r('app.string.dash_vpn_attached') : $r('app.string.dash_vpn_detached') }).layoutWeight(1)
      }
      .width('100%')
      Text($r('app.string.dash_vpn_capability'))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}
