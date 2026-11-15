import { uiResourceText } from '../../components/ResourceText';

@ComponentV2
export struct ProfileSheetHeader {
  @Param titleText: ResourceStr = '';
  @Param confirmLabel: ResourceStr = $r('app.string.action_save');
  @Param saving: boolean = false;
  @Param canSave: boolean = true;
  @BuilderParam actions: () => void = profileHeaderActions;
  @Event onSave: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};

  build() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(24).fontColor([$r('sys.color.font_primary')])
      }
      .width(40).height(40).padding(0)
      .enabled(!this.saving)
      .accessibilityText($r('app.string.action_cancel'))
      .onClick((): void => this.onClose())
      Text(this.titleText)
        .fontSize(17).lineHeight(22).fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center).layoutWeight(1)
      this.actions()
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        if (this.saving) {
          LoadingProgress().width(24).height(24).color($r('app.color.brand'))
        } else {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(24).fontColor([$r('app.color.brand')])
        }
      }
      .width(40).height(40).padding(0)
      .enabled(this.canSave && !this.saving)
      .accessibilityText(uiResourceText(this.getUIContext(), this.confirmLabel))
      .onClick((): void => this.onSave())
    }
    .width('100%').height(48).padding({ left: 16, right: 16 })
  }
}

@Builder
function profileHeaderActions() {}
