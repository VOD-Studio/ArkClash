import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';

@ComponentV2
export struct DashboardHeaderAction {
  @Param glyph: string = 'copy';
  @Param actionLabel: ResourceStr = '';
  @Param busy: boolean = false;
  @Param active: boolean = true;
  @Param xShift: number = 0;
  @Event onPress: () => void = () => {};


  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Button({ type: ButtonType.Circle }) {
        if (this.busy) {
          LoadingProgress().width(18).height(18)
        } else {
          AppGlyph({ name: this.glyph, iconSize: 18, iconColor: $r('sys.color.font_secondary') })
        }
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .enabled(this.active && !this.busy)
      .accessibilityText(uiResourceText(this.getUIContext(), this.actionLabel))
      .position({ x: this.xShift, y: -3 })
      .hitTestBehavior(HitTestMode.Block)
      .onClick((): void => { this.onPress(); })
    }
    .width(32)
    .height(26)
  }
}
