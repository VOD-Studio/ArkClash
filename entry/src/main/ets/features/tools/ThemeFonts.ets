import { text } from '@kit.ArkGraphics2D';
import { ListSource } from '../../components/ListSource';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { uiResourceText } from '../../components/ResourceText';
import { CARD_RADIUS, PAGE_GUTTER } from '../../components/Theme';

@ComponentV2
@ReusableV2
struct ThemeFontRow {
  @Param family: string = '';
  @Param chosen: boolean = false;
  @Param tint: number = 0;
  @Event onChoose: (family: string) => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text(this.family || $r('app.string.theme_default'))
            .fontSize(16).fontColor($r('sys.color.font_primary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.theme_font_sample')).fontFamily(this.family)
            .fontSize(15).fontColor($r('sys.color.font_secondary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).accessibilityLevel('no')
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.tint]).fontSize(18)
          .visibility(this.chosen ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%')
    }
    .width('100%').constraintSize({ minHeight: 64 })
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 10, bottom: 10 })
    .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(Color.Transparent)
    .accessibilityText(uiResourceText(this.getUIContext(), this.family || $r('app.string.theme_default')))
    .accessibilitySelected(this.chosen)
    .onClick(() => this.onChoose(this.family))
  }
}

@ComponentV2
export struct ThemeFonts {
  @Event onChoose: (family: string) => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  private readonly fonts: ListSource<string> = new ListSource<string>();
  private generation: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void { ++this.generation; }

  private async load(): Promise<void> {
    const generation = ++this.generation;
    this.loading = true;
    this.failed = false;
    try {
      const entries = await text.matchFontDescriptors({});
      if (generation !== this.generation) { return; }
      const families = new Set<string>();
      for (const entry of entries) {
        if (entry.fontFamily) { families.add(entry.fontFamily); }
      }
      this.fonts.replace(Array.from(families).sort((a: string, b: string): number => a.localeCompare(b)));
    } catch (_) {
      if (generation === this.generation) { this.failed = true; }
    } finally {
      if (generation === this.generation) { this.loading = false; }
    }
  }

  build() {
    List() {
      ListItem() {
        ThemeFontRow({ chosen: this.appStyle.fontFamily === '', tint: this.appStyle.palette.brand,
          onChoose: (family: string) => this.onChoose(family) })
      }
      .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(CARD_RADIUS).clip(true)
      if (this.loading) {
        ListItem() { LoadingProgress().width(28).height(28).margin(16) }
      } else if (this.failed) {
        ListItem() {
          Button($r('app.string.theme_font_retry')).margin(12).onClick(() => this.load())
        }
      } else if (this.fonts.totalCount() > 0) {
        ListItem() {
          Text($r('app.string.theme_installed_fonts')).fontSize(14).fontWeight(500)
            .fontColor($r('sys.color.font_secondary')).width('100%')
            .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 8 })
        }
        ListItemGroup() {
          LazyForEach(this.fonts, (family: string) => {
            ListItem() {
              ThemeFontRow({ family: family, chosen: this.appStyle.fontFamily === family,
                tint: this.appStyle.palette.brand, onChoose: (chosen: string) => this.onChoose(chosen) })
            }
          }, (family: string): string => family)
        }
        .divider({ strokeWidth: 0.5, startMargin: PAGE_GUTTER, endMargin: PAGE_GUTTER,
          color: this.appStyle.palette.divider })
        .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(CARD_RADIUS).clip(true)
      }
    }
    .width('100%').height('100%').cachedCount(2).scrollBar(BarState.Auto)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER }).contentEndOffset(PAGE_GUTTER)
  }
}
