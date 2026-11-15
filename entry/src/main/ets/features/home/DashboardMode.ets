import { CapsuleSegmentButtonV2, SegmentButtonV2Items, uiMaterial } from '@kit.ArkUI';
import { connection, Connection } from '../../client/Connection';
import { OutboundMode } from '../../client/Controller';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

const DASHBOARD_MODES: OutboundMode[] = ['rule', 'global', 'direct'];

@ComponentV2
export struct DashboardMode {
  @Param visible: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;
  private modeItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.mode_rule'), symbol: $r('sys.symbol.list_bullet') },
    { text: $r('app.string.mode_global'), symbol: $r('sys.symbol.paperplane') },
    { text: $r('app.string.mode_direct'), symbol: $r('sys.symbol.arrow_right') }
  ]);
  private appeared: boolean = false;

  aboutToAppear(): void { this.appeared = true; }
  aboutToDisappear(): void { this.appeared = false; }

  private async choose(index: number): Promise<void> {
    const mode = DASHBOARD_MODES[index];
    if (!this.appeared || !this.visible || !this.interactive || mode === undefined || mode === this.conn.mode ||
      this.conn.modePending || this.conn.busy) {
      return;
    }
    try {
      await this.conn.changeMode(mode);
    } catch (e) {
      if (this.appeared && this.visible) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_mode_failed') });
      }
    }
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: this.conn.modePending ? $r('app.string.dash_mode_pending') :
        $r('app.string.card_mode'), glyph: 'split' })
      CapsuleSegmentButtonV2({
        items: this.modeItems,
        selectedIndex: Math.max(0, DASHBOARD_MODES.indexOf(this.conn.mode as OutboundMode)),
        $selectedIndex: (index: number): void => { this.choose(index); },
        enableStateAnimation: this.motionEnabled,
        backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR })
      })
        .width('100%')
        .enabled(this.visible && this.interactive && !this.conn.modePending && !this.conn.busy)
        .accessibilityDescription(this.conn.modeError)
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
  }
}
