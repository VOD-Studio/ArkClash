import { uiResourceText } from '../../components/ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE,
  PAGE_GUTTER, SHEET_HEADER_HEIGHT } from '../../components/Theme';

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
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .enabled(!this.saving)
      .accessibilityText($r('app.string.action_cancel'))
      .onClick((): void => this.onClose())
      Text(this.titleText)
        .fontSize(COMPACT_TITLE_SIZE).lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center).layoutWeight(1)
      this.actions()
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
        if (this.saving) {
          LoadingProgress().width(HEADER_ICON_SIZE).height(HEADER_ICON_SIZE).color($r('app.color.brand'))
        } else {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(HEADER_ICON_SIZE).fontColor([$r('app.color.brand')])
        }
      }
      .attributeModifier(HEADER_ACTION)
      .enabled(this.canSave && !this.saving)
      .accessibilityText(uiResourceText(this.getUIContext(), this.confirmLabel))
      .onClick((): void => this.onSave())
    }
    .width('100%').height(SHEET_HEADER_HEIGHT).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }
}

@Builder
function profileHeaderActions() {}
