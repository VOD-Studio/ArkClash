import { text } from '@kit.ArkGraphics2D';
import { ListSource } from '../../components/ListSource';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { COMPACT_TITLE_SIZE, PAGE_GUTTER } from '../../components/Theme';

@ComponentV2
@ReusableV2
struct ThemeFontRow {
  @Param family: string = '';
  @Param chosen: boolean = false;
  @Param tint: number = 0;
  @Event onChoose: (family: string) => void = () => {};

  build() {
    Button() {
      Row({ space: 12 }) {
        Text(this.family === '' ? $r('app.string.theme_default') : this.family)
          .fontFamily(this.family).fontSize(17).fontColor($r('sys.color.font_primary'))
          .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.chosen) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.tint]).fontSize(18)
        }
      }
      .width('100%')
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(Color.Transparent)
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
    Column({ space: 12 }) {
      Text($r('app.string.theme_font')).fontFamily(this.appStyle.fontFamily)
        .fontSize(COMPACT_TITLE_SIZE).fontWeight(600).width('100%').padding({ left: 16, right: 44 })
      List() {
        ListItem() {
          ThemeFontRow({ chosen: this.appStyle.fontFamily === '', tint: this.appStyle.palette.brand,
            onChoose: (family: string) => this.onChoose(family) })
        }
        LazyForEach(this.fonts, (family: string) => {
          ListItem() {
            ThemeFontRow({ family: family, chosen: this.appStyle.fontFamily === family,
              tint: this.appStyle.palette.brand,
              onChoose: (chosen: string) => this.onChoose(chosen) })
          }
        }, (family: string): string => family)
        if (this.loading) {
          ListItem() { LoadingProgress().width(28).height(28).margin(16) }
        } else if (this.failed) {
          ListItem() {
            Button($r('app.string.theme_font_retry')).fontFamily(this.appStyle.fontFamily)
              .margin(12).onClick(() => this.load())
          }
        }
      }
      .width('100%').layoutWeight(1).cachedCount(2).scrollBar(BarState.Auto)
      .divider({ strokeWidth: 0.5, startMargin: 16, endMargin: 16, color: this.appStyle.palette.divider })
    }
    .width('100%').height('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 16 })
  }
}
