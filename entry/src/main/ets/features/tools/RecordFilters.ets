import { UIContext } from '@kit.ArkUI';
import { AppGlyph } from '../../components/AppGlyph';
import { uiResourceText } from '../../components/ResourceText';
import { sheetMaterial } from '../../components/Theme';
import { RecordFacets, RecordGrouping } from './RecordLogic';
import { recordColumnTitle, recordFacetText } from './RecordLabels';

export interface RecordMenuOption {
  key: string;
  title: ResourceStr;
}

interface RecordFilterChip {
  key: string;
  field: string;
  option: string;
  title: ResourceStr;
  text: ResourceStr;
}

export function recordGroupingText(grouping: RecordGrouping): ResourceStr {
  switch (grouping) {
    case 'host': return $r('app.string.diagnostics_group_host');
    case 'rule': return $r('app.string.diagnostics_group_rule');
    case 'exit': return $r('app.string.diagnostics_group_exit');
    default: return $r('app.string.diagnostics_group_none');
  }
}

// 选择仅在原生面板完全退出后交付，下一层菜单不会与前一层竞争。
export function showRecordMenu(context: UIContext, title: ResourceStr, options: RecordMenuOption[],
  onResult: (choice: string) => void): void {
  let choice = '';
  const sheets: SheetInfo[] = options.map<SheetInfo>((option: RecordMenuOption): SheetInfo => {
    return { title: option.title, action: (): void => { choice = option.key; } };
  });
  context.showActionSheet({
    title: title, message: '', sheets: sheets, alignment: DialogAlignment.Bottom,
    systemMaterial: sheetMaterial(), autoCancel: true,
    confirm: { value: $r('app.string.diagnostics_cancel'), action: (): void => {} },
    onDidDisappear: (): void => { onResult(choice); }
  });
}

@ComponentV2
export struct RecordFilterChips {
  @Param facets: RecordFacets = {};
  @Event onRemove: (field: string, option: string) => void = () => {};

  @Computed
  get chips(): RecordFilterChip[] {
    const result: RecordFilterChip[] = [];
    for (const field of Object.keys(this.facets)) {
      for (const option of this.facets[field]) {
        result.push({ key: `${field}:${option}`, field: field, option: option,
          title: recordColumnTitle(field === 'proxy' ? 'chains' : field), text: recordFacetText(field, option) });
      }
    }
    return result;
  }

  build() {
    Column() {
    if (this.chips.length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.chips, (chip: RecordFilterChip) => {
            Button({ type: ButtonType.Capsule }) {
              Row({ space: 6 }) {
                Text(chip.title).fontSize(13).fontColor($r('sys.color.font_secondary'))
                Text(chip.text).fontSize(14).fontColor($r('sys.color.font_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                AppGlyph({ name: 'close', iconSize: 12 })
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            }
            .constraintSize({ maxWidth: 320 })
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor($r('app.color.surface_block'))
            .accessibilityText(uiResourceText(this.getUIContext(), chip.text))
            .accessibilityDescription($r('app.string.diagnostics_filters'))
            .onClick((): void => { this.onRemove(chip.field, chip.option); })
          }, (chip: RecordFilterChip): string => chip.key)
        }
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    }
    .width('100%')
  }
}
