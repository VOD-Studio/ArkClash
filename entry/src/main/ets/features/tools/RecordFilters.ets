import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { ListSource } from '../../components/ListSource';
import { uiResourceText } from '../../components/ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, PAGE_GUTTER } from '../../components/Theme';
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
@ObservedV2
export class RecordMenuState {
  @Trace shown: boolean = false;
  @Trace title: ResourceStr = '';
  @Trace optionCount: number = 0;
  readonly rows: ListSource<RecordMenuOption> = new ListSource<RecordMenuOption>();
  private choice: string = '';
  private onResult: ((choice: string) => void) | undefined = undefined;

  open(title: ResourceStr, options: RecordMenuOption[], onResult: (choice: string) => void): void {
    this.title = title;
    this.optionCount = options.length;
    this.rows.replace(options);
    this.choice = '';
    this.onResult = onResult;
    this.shown = true;
  }

  select(choice: string): void {
    if (!this.shown) { return; }
    this.choice = choice;
    this.shown = false;
  }

  finish(): void {
    const onResult = this.onResult;
    const choice = this.choice;
    this.onResult = undefined;
    this.choice = '';
    this.rows.replace([]);
    onResult?.(choice);
  }
}

@ComponentV2
export struct RecordActionMenu {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require menuState: RecordMenuState;

  @Builder
  MenuContent() {
    Column() {
      Text(this.menuState.title).fontFamily(this.appStyle.fontFamily).fontSize(COMPACT_TITLE_SIZE).lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
        .fontColor($r('sys.color.font_primary')).width('100%').margin({ bottom: 16 })
      List() {
        LazyForEach(this.menuState.rows, (option: RecordMenuOption) => {
          ListItem() {
            RecordMenuRow({ option: option, onSelect: (key: string): void => { this.menuState.select(key); } })
          }
        }, (option: RecordMenuOption): string => option.key)
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto).cachedCount(2)
      .divider({ strokeWidth: 0.5, color: this.appStyle.palette.divider, startMargin: 16, endMargin: 16 })
      Button($r('app.string.diagnostics_cancel'))
        .fontFamily(this.appStyle.fontFamily)
        .width('100%').constraintSize({ minHeight: 48 }).margin({ top: 16 })
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => { this.menuState.select(''); })
    }
    .width('100%').height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 24 })
  }

  build() {
    Column()
      .bindSheet($$this.menuState.shown, this.MenuContent, {
        height: this.menuState.optionCount * 56 + 180, preferType: SheetType.BOTTOM,
        systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
        onDisappear: (): void => { this.menuState.finish(); }
      })
  }
}

@ComponentV2
@ReusableV2
struct RecordMenuRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require option: RecordMenuOption;
  @Event onSelect: (key: string) => void = () => {};

  build() {
    Button() {
      Text(this.option.title).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(24).fontColor($r('sys.color.font_primary'))
        .width('100%').textAlign(TextAlign.Start)
    }
    .width('100%').constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(Color.Transparent).borderRadius(12)
    .accessibilityText(uiResourceText(this.getUIContext(), this.option.title))
    .onClick((): void => { this.onSelect(this.option.key); })
  }
}

@ComponentV2
export struct RecordFilterChips {
  @Local private appStyle: AppearanceState = appAppearance;
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
                Text(chip.title).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
                Text(chip.text).fontFamily(this.appStyle.fontFamily).fontSize(14).fontColor($r('sys.color.font_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                AppGlyph({ name: 'close', iconSize: 12 })
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            }
            .constraintSize({ maxWidth: 320 })
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor(this.appStyle.palette.surfaceBlock)
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
