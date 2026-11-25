import { IconSetImage, iconSetLabel } from '../shared/profiles/IconSetModel';
import { AppearanceState, appAppearance } from './AppearanceState';
import { EmptyState } from './EmptyState';
import { ListSource } from './ListSource';
import { PAGE_GUTTER } from './Theme';

class IconSetGridEntry {
  key: string;
  icon: IconSetImage;

  constructor(icon: IconSetImage, key: string) {
    this.icon = icon;
    this.key = key;
  }
}

@ComponentV2
export struct IconSetThumbnail {
  @Param source: string = '';
  @Param edge: number = 40;
  @Local private failed: boolean = false;

  @Monitor('source')
  reset(): void { this.failed = false; }

  build() {
    Stack() {
      if (this.failed || this.source === '') {
        SymbolGlyph($r('sys.symbol.picture')).fontSize(this.edge * 0.56).fontColor([$r('sys.color.font_tertiary')])
      } else {
        Image(this.source).objectFit(ImageFit.Contain).width(this.edge).height(this.edge)
          .sourceSize({ width: 160, height: 160 })
          .onError((): void => { this.failed = true; })
      }
    }.width(this.edge).height(this.edge).accessibilityLevel('no')
  }
}

@ComponentV2
@ReusableV2
struct IconSetCell {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: IconSetImage;
  @Param picked: boolean = false;
  @Param selectable: boolean = false;
  @Event onPick: () => void = () => {};

  @Builder
  Picture() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        IconSetThumbnail({ source: this.icon.url, edge: 40 })
      }.justifyContent(FlexAlign.Center).width(56).height(56).borderRadius(14)
        .backgroundColor(this.picked ? this.appStyle.palette.selectionTonal : this.appStyle.palette.surfaceBlock)
      if (this.picked) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(15).fontColor([this.appStyle.palette.brand])
      }
    }.width(56).height(56)
  }

  build() {
    Column({ space: 6 }) {
      if (this.selectable) {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL, stateEffect: true }) {
          this.Picture()
        }.width(56).height(56).padding(0)
          .accessibilityText(this.icon.name).accessibilitySelected(this.picked).onClick((): void => this.onPick())
      } else {
        this.Picture()
      }
      Text(iconSetLabel(this.icon.name) || $r('app.string.icon_set_embedded')).fontSize(12).fontFamily(this.appStyle.fontFamily)
        .fontColor($r('sys.color.font_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center)
    }.width('100%').height(80).alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
export struct IconSetGrid {
  @Param icons: IconSetImage[] = [];
  @Param query: string = '';
  @Param selected: string = '';
  @Param selectable: boolean = false;
  @Event onPick: (icon: IconSetImage) => void = (_icon: IconSetImage): void => {};
  @Local private count: number = 0;
  @Local private columns: string = '1fr 1fr 1fr 1fr';
  private source: ListSource<IconSetGridEntry> = new ListSource<IconSetGridEntry>();

  aboutToAppear(): void { this.refresh(); }

  @Monitor('icons', 'query')
  refresh(): void {
    const terms = this.query.toLowerCase().trim().split(/\s+/);
    const rows: IconSetGridEntry[] = [];
    for (let index = 0; index < this.icons.length; index++) {
      const icon = this.icons[index];
      const label = iconSetLabel(icon.name).toLowerCase();
      if (terms.every((term: string): boolean => label.includes(term))) {
        // 清单中没有图标 ID，按该清单中图标的原始位置稳定标识筛选结果。
        const source = icon.url;
        const key = `${index}:${icon.name}:${source.length}:${source.slice(0, 128)}:${source.slice(-32)}`;
        rows.push(new IconSetGridEntry(icon, key));
      }
    }
    this.count = rows.length;
    this.source.replace(rows);
  }

  private measure(width: number): void {
    if (Number.isFinite(width) && width > 0) {
      const count = Math.max(2, Math.floor((width - PAGE_GUTTER * 2) / 76));
      this.columns = '1fr '.repeat(count).trim();
    }
  }

  build() {
    Column() {
      if (this.count === 0) {
        EmptyState({ icon: $r('sys.symbol.picture'),
          title: this.query.trim() === '' ? $r('app.string.icon_sets_empty') :
            $r('app.string.diagnostics_no_matches') }).layoutWeight(1)
      } else {
        Grid() {
          LazyForEach(this.source, (entry: IconSetGridEntry) => {
            GridItem() {
              IconSetCell({ icon: entry.icon, picked: this.selected === entry.icon.url, selectable: this.selectable,
                onPick: (): void => this.onPick(entry.icon) })
            }
          }, (entry: IconSetGridEntry): string => entry.key)
        }.layoutWeight(1).width('100%').columnsTemplate(this.columns).columnsGap(8).rowsGap(8)
          .cachedCount(2, true).scrollBar(BarState.Off)
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 20 })
          .safeAreaPadding({ top: 12 })
          .clipContent(ContentClipMode.SAFE_AREA)
      }
    }.width('100%').height('100%')
      .onAreaChange((_oldArea: Area, area: Area): void => this.measure(Number(area.width)))
  }
}
