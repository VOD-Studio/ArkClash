import { LengthMetrics } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { AppGlyph } from '../../components/AppGlyph';
import { uiResourceText } from '../../components/ResourceText';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, PAGE_GUTTER,
  SHEET_HEADER_HEIGHT } from '../../components/Theme';
import { recordColumnTitle, recordFacetText } from './RecordLabels';
import { RecordFacets, recordFacetsAfterToggle } from './RecordLogic';
import { DnsRecordsStore } from './RecordStores';

interface DnsFilterField {
  field: string;
  glyph: string;
}

interface DnsFilterGroup extends DnsFilterField {
  options: string[];
}

const DNS_FILTER_FIELDS: DnsFilterField[] = [
  { field: 'type', glyph: 'layers' }, { field: 'initiator', glyph: 'proxies' },
  { field: 'cache', glyph: 'clock' }, { field: 'rcode', glyph: 'status' }
];

@ComponentV2
export struct DnsFilterSheet {
  @Param @Require store: DnsRecordsStore;
  @Param reduceMotion: boolean = true;
  @Event onClose: () => void = () => {};
  @Event onApply: (facets: RecordFacets) => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private draft: RecordFacets = {};
  @Local private groups: DnsFilterGroup[] = [];

  aboutToAppear(): void {
    this.draft = this.store.facets;
    this.loadOptions();
  }

  @Computed
  get hasHistory(): boolean { return this.store.totalRecords > 0; }

  @Computed
  get canReset(): boolean {
    return Object.keys(this.draft).some((key: string): boolean => this.draft[key].length > 0);
  }

  @Monitor('hasHistory')
  offerFirstRecords(): void {
    if (this.hasHistory && this.groups.length === 0) { this.loadOptions(); }
  }

  private loadOptions(): void {
    // 用户连选时保持选项位置稳定，下一次打开再按最新记录排序。
    const groups: DnsFilterGroup[] = [];
    for (const item of DNS_FILTER_FIELDS) {
      const options = this.store.facetOptions(item.field);
      if (options.length > 0) { groups.push({ field: item.field, glyph: item.glyph, options: options }); }
    }
    this.groups = groups;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text($r('app.string.diagnostics_dns_filters'))
          .fontFamily(this.appStyle.fontFamily).fontSize(COMPACT_TITLE_SIZE)
          .lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600).fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppGlyph({ name: 'close', iconSize: 18 })
        }
        .attributeModifier(HEADER_ACTION).backgroundColor(this.appStyle.palette.surfaceBlock)
        .accessibilityText($r('app.string.diagnostics_cancel')).onClick((): void => this.onClose())
      }
      .width('100%').constraintSize({ minHeight: SHEET_HEADER_HEIGHT }).padding({ left: 4 })

      if (this.groups.length > 0) {
        List({ space: 8 }) {
          ForEach(this.groups, (group: DnsFilterGroup) => {
            ListItem() {
              DnsFilterSection({ group: group, selection: this.draft[group.field] ?? [], reduceMotion: this.reduceMotion,
                onToggle: (option: string): void => {
                  this.draft = recordFacetsAfterToggle(this.draft, group.field, option);
                } })
            }
          }, (group: DnsFilterGroup): string => group.field)
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Auto).contentStartOffset(4).contentEndOffset(4)

        Row({ space: 12 }) {
          Button($r('app.string.theme_reset'))
            .fontFamily(this.appStyle.fontFamily).fontSize(16).fontWeight(500)
            .fontColor($r('sys.color.font_primary')).backgroundColor(this.appStyle.palette.surfaceBlock)
            .constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(this.canReset)
            .onClick((): void => { this.draft = {}; })
          Button($r('app.string.diagnostics_apply_filters'))
            .fontFamily(this.appStyle.fontFamily).fontSize(16).fontWeight(600)
            .fontColor(this.appStyle.palette.onBrand).backgroundColor(this.appStyle.palette.brand)
            .constraintSize({ minHeight: 48 }).layoutWeight(2)
            .onClick((): void => this.onApply(this.draft))
        }
        .width('100%').padding({ top: 12, bottom: 8 })
      } else {
        Column({ space: 12 }) {
          Stack() {
            AppGlyph({ name: 'search', iconSize: 24, iconColor: this.appStyle.palette.brand })
          }
          .width(52).height(52).borderRadius(18).backgroundColor(this.appStyle.palette.brandSoft)
          Text($r('app.string.diagnostics_no_filter_options'))
            .fontFamily(this.appStyle.fontFamily).fontSize(15).fontColor($r('sys.color.font_secondary'))
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
  }
}

@ComponentV2
struct DnsFilterSection {
  @Param @Require group: DnsFilterGroup;
  @Param @Require selection: string[];
  @Param reduceMotion: boolean = true;
  @Event onToggle: (option: string) => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Column() {
      Row({ space: 8 }) {
        AppGlyph({ name: this.group.glyph, iconSize: 18, iconColor: this.appStyle.palette.brand })
        Text(recordColumnTitle(this.group.field))
          .fontFamily(this.appStyle.fontFamily).fontSize(16).fontWeight(600)
          .fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Text(this.selection.length === 0 ? $r('app.string.diagnostics_filter_any') :
          $r('app.string.diagnostics_filter_count', this.selection.length))
          .fontFamily(this.appStyle.fontFamily).fontSize(12)
          .fontColor(this.selection.length === 0 ? $r('sys.color.font_secondary') : this.appStyle.palette.brand)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8) } }) {
        ForEach(this.group.options, (option: string) => {
          DnsFilterChoice({ label: recordFacetText(this.group.field, option),
            chosen: this.selection.includes(option), reduceMotion: this.reduceMotion,
            onPress: (): void => this.onToggle(option) })
        }, (option: string): string => option)
      }
      .width('100%')
    }
    .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 2 })
    .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22)
  }
}

@ComponentV2
struct DnsFilterChoice {
  @Param @Require label: ResourceStr;
  @Param chosen: boolean = false;
  @Param reduceMotion: boolean = true;
  @Event onPress: () => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 6 }) {
        Stack() {
          AppGlyph({ name: 'check', iconSize: 10, iconColor: this.appStyle.palette.onBrand })
            .opacity(this.chosen ? 1 : 0).scale({ x: this.chosen ? 1 : 0.55, y: this.chosen ? 1 : 0.55 })
            .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
        }
        .width(15).height(15).borderRadius(8)
        .border({ width: 1, color: this.chosen ? this.appStyle.palette.brand : $r('sys.color.icon_secondary') })
        .backgroundColor(this.chosen ? this.appStyle.palette.brand : Color.Transparent)
        .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
        Text(this.label)
          .fontFamily(this.appStyle.fontFamily).fontSize(14).fontWeight(500)
          .fontColor(this.chosen ? this.appStyle.palette.brand : $r('sys.color.font_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      }
      .padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(16)
      .backgroundColor(this.chosen ? this.appStyle.palette.selectionTonal : this.appStyle.palette.surfaceBlock)
      .animation({ duration: this.reduceMotion ? 0 : 160, curve: Curve.EaseOut })
    }
    .constraintSize({ minHeight: 56, maxWidth: '100%' }).padding({ top: 9, bottom: 9 })
    .backgroundColor(Color.Transparent).accessibilityText(uiResourceText(this.getUIContext(), this.label))
    .accessibilitySelected(this.chosen).onClick((): void => this.onPress())
  }
}
