import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { CapsuleSegmentButtonV2, ColorMetrics, SegmentButtonV2Items, TextModifier } from '@kit.ArkUI';
import { connection, Connection } from '../../client/Connection';
import { OutboundMode } from '../../client/Controller';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

const DASHBOARD_MODES: OutboundMode[] = ['rule', 'global', 'direct'];

@ComponentV2
export struct DashboardMode {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param visible: boolean = false;
  @Param motionEnabled: boolean = false;
  @Param interactive: boolean = true;
  @Local conn: Connection = connection;

  @Computed
  get modeItems(): SegmentButtonV2Items {
    const labelStyle = new TextModifier().fontFamily(this.appStyle.fontFamily);
    return new SegmentButtonV2Items([
      { text: $r('app.string.mode_rule'), symbol: $r('sys.symbol.list_bullet'), textModifier: labelStyle },
      { text: $r('app.string.mode_global'), symbol: $r('sys.symbol.paperplane'), textModifier: labelStyle },
      { text: $r('app.string.mode_direct'), symbol: $r('sys.symbol.arrow_right'), textModifier: labelStyle }
    ]);
  }

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
        itemSelectedBackgroundColor: ColorMetrics.numeric(this.appStyle.palette.brand),
        itemSelectedFontColor: ColorMetrics.numeric(this.appStyle.palette.onBrand),
        itemSelectedSymbolFontColor: ColorMetrics.numeric(this.appStyle.palette.onBrand),
        backgroundSystemMaterial: this.appStyle.regularMaterial()
      })
        .width('100%')
        .enabled(this.visible && this.interactive && !this.conn.modePending && !this.conn.busy)
        .accessibilityDescription(this.conn.modeError)
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }
}
