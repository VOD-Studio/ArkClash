import { AppearanceGlass } from '../../components/AppearanceState';
import { AppearancePalette } from '../../components/AppearancePalette';

const PREVIEW_ICONS: Resource[] = [$r('sys.symbol.house'), $r('sys.symbol.paperplane'),
  $r('sys.symbol.doc_text'), $r('sys.symbol.square_grid_2x2')];
const PREVIEW_LABELS: Resource[] = [$r('app.string.tab_home'), $r('app.string.tab_proxies'),
  $r('app.string.tab_profiles'), $r('app.string.tab_tools')];
const PREVIEW_TABS: number[] = [0, 1, 2, 3];

interface ThemePreviewPaint {
  palette: AppearancePalette;
}

@ComponentV2
export struct ThemePreview {
  @Param @Require colors: AppearancePalette;
  @Param otherColors: AppearancePalette | undefined = undefined;
  @Param floating: boolean = true;
  @Param glass: AppearanceGlass = 'standard';
  @Param compact: boolean = true;
  @Param pageIndex: number = 0;
  @Event onPreviewTab: (index: number) => void = () => {};

  @Builder
  Sketch($$: ThemePreviewPaint) {
    Column({ space: this.compact ? 4 : 7 }) {
      Row() {
        Blank().width('33%').height(this.compact ? 4 : 8).backgroundColor($$.palette.brand).borderRadius(8)
        Blank()
        Circle().width(this.compact ? 5 : 10).height(this.compact ? 5 : 10).fill($$.palette.brand)
      }
      .width('100%').margin({ bottom: 2 })
      if (this.pageIndex === 0) {
        Row({ space: this.compact ? 4 : 8 }) {
          Blank().layoutWeight(1).height('100%').backgroundColor($$.palette.cardBackground).borderRadius(8)
          Blank().layoutWeight(1).height('100%').backgroundColor($$.palette.dashStatusDecoration).borderRadius(8)
        }
        .height(this.compact ? 14 : 26).width('100%')
      }
      ForEach(this.pageIndex === 1 ? [0, 1, 2, 3] : this.pageIndex === 0 ? [0, 1] : [0, 1, 2], (item: number) => {
        Row({ space: 6 }) {
          Circle().width(this.compact ? 4 : 8).height(this.compact ? 4 : 8)
            .fill(item === 0 ? $$.palette.brand : $$.palette.dashSeriesSecondary)
          Blank().width(item % 2 === 0 ? '38%' : '61%').height(this.compact ? 3 : 5)
            .backgroundColor($$.palette.dashSeriesSecondary).borderRadius(8)
        }
        .height(this.compact ? 9 : 19).width('100%').padding({ left: 5 })
        .borderRadius(this.compact ? 3 : 7).backgroundColor($$.palette.cardBackground)
      }, (item: number): string => `${item}`)
    }
    .layoutWeight(1).width('100%').alignItems(HorizontalAlign.Start)
    .padding(this.compact ? 6 : 12)
  }

  @Builder
  Bar($$: ThemePreviewPaint) {
    Row() {
      ForEach(PREVIEW_TABS, (index: number) => {
        if (this.compact) {
          Circle().width(4).height(4).fill(index === this.pageIndex ? $$.palette.brand : $$.palette.dashSeriesSecondary)
        } else {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(PREVIEW_ICONS[index]).fontSize(18)
              .fontColor([index === this.pageIndex ? $$.palette.brand : $$.palette.dashSeriesSecondary])
          }
          .width(44).height(36).padding(0).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(index === this.pageIndex ? $$.palette.brandSoft : Color.Transparent)
          .accessibilityText(PREVIEW_LABELS[index]).accessibilitySelected(index === this.pageIndex)
          .id(`theme-preview-${index}`)
          .onClick(() => this.onPreviewTab(index))
        }
      }, (index: number): string => `${index}`)
    }
    .justifyContent(FlexAlign.SpaceEvenly)
    .width('100%').height(this.compact ? 12 : 42)
    .padding({ left: this.compact ? 0 : 4, right: this.compact ? 0 : 4 })
    .borderRadius(this.floating ? 24 : 0)
    .backgroundColor(this.floating && this.glass !== 'none' ? $$.palette.tileBackground : $$.palette.cardBackground)
  }

  @Builder
  Screen($$: ThemePreviewPaint) {
    Column() {
      this.Sketch({ palette: $$.palette })
      Column() { this.Bar({ palette: $$.palette }) }
        .width('100%').padding(this.floating ? this.compact ? 3 : 7 : 0)
    }
    .width('100%').height('100%').backgroundColor($$.palette.pageBackground)
  }

  build() {
    Row() {
      if (this.otherColors !== undefined) {
        Column() { this.Screen({ palette: this.colors }) }.layoutWeight(1).height('100%')
        Column() { this.Screen({ palette: this.otherColors }) }.layoutWeight(1).height('100%')
      } else {
        this.Screen({ palette: this.colors })
      }
    }
    .width(this.compact ? '100%' : '90%').height(this.compact ? 86 : 170)
    .borderRadius(this.compact ? 10 : 18)
    .border({ width: 1, color: this.colors.divider })
    .clip(true)
  }
}
