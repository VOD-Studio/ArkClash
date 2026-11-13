import { CapsuleSegmentButtonV2, SegmentButtonV2Items, uiMaterial } from '@kit.ArkUI';
import { connection, Connection } from '../../client/Connection';
import { OutboundMode } from '../../client/Controller';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

const DASHBOARD_MODES: OutboundMode[] = ['rule', 'global', 'direct'];

@ComponentV2
export struct DashboardMode {
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;
  @Local requested: OutboundMode | '' = '';
  private modeItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.mode_rule'), symbol: $r('sys.symbol.list_bullet') },
    { text: $r('app.string.mode_global'), symbol: $r('sys.symbol.paperplane') },
    { text: $r('app.string.mode_direct'), symbol: $r('sys.symbol.arrow_right') }
  ]);

  private async choose(index: number): Promise<void> {
    const mode = DASHBOARD_MODES[index];
    if (!this.interactive || mode === undefined || mode === this.conn.mode || this.conn.modePending || this.conn.busy) {
      return;
    }
    this.requested = mode;
    try {
      await this.conn.changeMode(mode);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_mode_failed') });
    } finally {
      this.requested = '';
    }
  }

  build() {
    Column({ space: 8 }) {
      DashboardCardHeader({ title: $r('app.string.card_mode'), symbol: $r('sys.symbol.route') })
      CapsuleSegmentButtonV2({
        items: this.modeItems,
        selectedIndex: Math.max(0, DASHBOARD_MODES.indexOf(this.conn.mode as OutboundMode)),
        $selectedIndex: (index: number): void => { this.choose(index); },
        enableStateAnimation: false,
        backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR })
      })
        .enabled(this.interactive && !this.conn.modePending && !this.conn.busy)
      if (this.conn.modePending || this.requested !== '') {
        Text($r('app.string.dash_mode_pending'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      } else if (this.conn.modeError !== '') {
        Text($r('app.string.dash_mode_failed'))
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
      } else if (!this.conn.connected) {
        Text($r('app.string.dash_mode_next_start'))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}
