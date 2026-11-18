import { AppearanceColorStyle, AppearancePalette, DEFAULT_APPEARANCE_SEED, appearanceHex, appearanceInk,
  appearancePalette, parseAppearanceHex } from '../../components/AppearancePalette';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { CARD_RADIUS, COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE,
  PAGE_GUTTER, SECTION_GAP, SHEET_HEADER_HEIGHT } from '../../components/Theme';

const THEME_PAD_HEIGHT = 180;
const THEME_PAD_THUMB = 28;
const THEME_HEX_FORMAT = '#RRGGBB';

function themeColorClamp(fraction: number): number {
  return Math.max(0, Math.min(1, fraction));
}

function themeHsvColor(hue: number, saturation: number, brightness: number): number {
  const sector = (hue % 360) / 60;
  const chroma = brightness * saturation;
  const base = brightness - chroma;
  const mid = chroma * (1 - Math.abs(sector % 2 - 1));
  const band = Math.floor(sector);
  const red = band === 0 || band === 5 ? chroma : band === 1 || band === 4 ? mid : 0;
  const green = band === 1 || band === 2 ? chroma : band === 0 || band === 3 ? mid : 0;
  const blue = band === 3 || band === 4 ? chroma : band === 2 || band === 5 ? mid : 0;
  return (0xFF000000 | Math.round((red + base) * 255) << 16 |
    Math.round((green + base) * 255) << 8 | Math.round((blue + base) * 255)) >>> 0;
}

@ComponentV2
struct ThemeColorMiniScreen {
  @Param @Require preview: AppearancePalette;
  @Param @Require modeLabel: Resource;
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Column({ space: 4 }) {
      Column() {
        Row().width(29).height(4).borderRadius(2).backgroundColor(appearanceInk(this.preview.pageBackground))
        Row() {
          Row().width(26).height(4).borderRadius(2).backgroundColor(this.preview.onBrand)
        }
        .width('100%').height(24).borderRadius(8).justifyContent(FlexAlign.Center).backgroundColor(this.preview.brand)
        Row({ space: 4 }) {
          Row().layoutWeight(1).height(18).borderRadius(5).backgroundColor(this.preview.cardBackground)
          Row().layoutWeight(1).height(18).borderRadius(5).backgroundColor(this.preview.tileBackground)
        }
        .width('100%')
        Row({ space: 5 }) {
          Row().width(16).height(7).borderRadius(4).backgroundColor(this.preview.brand)
          Row().width(7).height(7).borderRadius(4).backgroundColor(this.preview.track)
          Row().width(7).height(7).borderRadius(4).backgroundColor(this.preview.track)
        }
        .width('100%').height(15).borderRadius(8).justifyContent(FlexAlign.Center)
        .backgroundColor(this.preview.surfaceBlock)
      }
      .width('100%')
      .height(96)
      .padding(7)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.SpaceBetween)
      .backgroundColor(this.preview.pageBackground)
      .borderRadius(CARD_RADIUS)
      .border({ width: 1, color: this.preview.divider })
      .accessibilityLevel('no-hide-descendants')
      Text(this.modeLabel)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width(72)
  }
}

@ComponentV2
export struct ThemeColorEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require seed: number;
  @Param @Require pureBlack: boolean;
  @Param @Require colorStyle: AppearanceColorStyle;
  @Event onCancel: () => void = (): void => {};
  @Event onConfirm: (seed: number) => void = (_seed: number): void => {};
  @Local draftSeed: number = DEFAULT_APPEARANCE_SEED;
  @Local hexInput: string = appearanceHex(DEFAULT_APPEARANCE_SEED);
  @Local hexIsValid: boolean = true;
  @Local hsvHue: number = 0;
  @Local hsvSaturation: number = 0;
  @Local hsvBrightness: number = 0;
  @Local padWidth: number = 0;
  private padPointer: number = -1;
  private readonly hueTrack: LinearGradient = new LinearGradient([
    { color: 0xFFFF0000, offset: 0 }, { color: 0xFFFFFF00, offset: 1 / 6 },
    { color: 0xFF00FF00, offset: 2 / 6 }, { color: 0xFF00FFFF, offset: 3 / 6 },
    { color: 0xFF0000FF, offset: 4 / 6 }, { color: 0xFFFF00FF, offset: 5 / 6 },
    { color: 0xFFFF0000, offset: 1 }
  ]);

  aboutToAppear(): void {
    this.setRgb(this.seed);
    this.hexInput = appearanceHex(this.seed);
  }

  @Computed
  get lightPreview(): AppearancePalette {
    return appearancePalette(this.draftSeed, false, this.pureBlack, this.colorStyle);
  }

  @Computed
  get darkPreview(): AppearancePalette {
    return appearancePalette(this.draftSeed, true, this.pureBlack, this.colorStyle);
  }

  @Computed
  get hueTint(): number {
    return themeHsvColor(this.hsvHue, 1, 1);
  }

  private setRgb(next: number): void {
    const red = (next >>> 16 & 255) / 255;
    const green = (next >>> 8 & 255) / 255;
    const blue = (next & 255) / 255;
    const max = Math.max(red, green, blue);
    const chroma = max - Math.min(red, green, blue);
    let sector = 0;
    if (chroma > 0) {
      if (max === red) {
        sector = (green - blue) / chroma;
      } else if (max === green) {
        sector = (blue - red) / chroma + 2;
      } else {
        sector = (red - green) / chroma + 4;
      }
    }
    this.hsvHue = (sector * 60 + 360) % 360;
    this.hsvSaturation = max === 0 ? 0 : chroma / max;
    this.hsvBrightness = max;
    this.draftSeed = next;
  }

  private editHex(text: string): void {
    if (text === this.hexInput) {
      return;
    }
    this.hexInput = text;
    const next = parseAppearanceHex(text);
    this.hexIsValid = next !== undefined;
    if (next !== undefined && next !== this.draftSeed) {
      this.setRgb(next);
    }
  }

  private pickHsv(hue: number, saturation: number, brightness: number): void {
    // 转成 RGB 再反推会丢失灰色的色相和黑色的饱和度，保留滑块的原值。
    this.hsvHue = hue;
    this.hsvSaturation = saturation;
    this.hsvBrightness = brightness;
    const next = themeHsvColor(hue, saturation, brightness);
    if (next !== this.draftSeed || !this.hexIsValid) {
      this.draftSeed = next;
      this.hexInput = appearanceHex(next);
      this.hexIsValid = true;
    }
  }

  private touchPad(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.padPointer = -1;
      return;
    }
    if (this.padWidth <= 0 || event.changedTouches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down && this.padPointer === -1) {
      this.padPointer = event.changedTouches[0].id;
    }
    for (const point of event.changedTouches) {
      if (point.id !== this.padPointer) {
        continue;
      }
      this.pickHsv(this.hsvHue, themeColorClamp(point.x / this.padWidth),
        1 - themeColorClamp(point.y / THEME_PAD_HEIGHT));
      if (event.type === TouchType.Up) {
        this.padPointer = -1;
      }
      return;
    }
  }

  @Builder
  Header() {
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.theme_cancel'))
      .onClick((): void => this.onCancel())
      Text($r('app.string.theme_custom_color'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(COMPACT_TITLE_SIZE).lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
        .fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(HEADER_ICON_SIZE).fontColor([this.appStyle.palette.brand])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .enabled(this.hexIsValid)
      .accessibilityText($r('app.string.theme_confirm'))
      .onClick((): void => {
        if (this.hexIsValid) {
          this.onConfirm(this.draftSeed);
        }
      })
    }
    .width('100%').height(SHEET_HEADER_HEIGHT).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  PreviewAndHex() {
    Row({ space: SECTION_GAP }) {
      ThemeColorMiniScreen({ preview: this.lightPreview, modeLabel: $r('app.string.theme_light') })
      ThemeColorMiniScreen({ preview: this.darkPreview, modeLabel: $r('app.string.theme_dark') })
      Column({ space: 4 }) {
        Text($r('app.string.theme_hex'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13).fontColor($r('sys.color.font_primary'))
          .accessibilityLevel('no')
        TextInput({ text: this.hexInput })
          .width('100%').constraintSize({ minHeight: 44 })
          .padding({ left: 8, right: 8 })
          .fontFamily('monospace').fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor(this.appStyle.palette.tileBackground)
          .borderRadius(12)
          .border({ width: 1, color: this.hexIsValid ? this.appStyle.palette.divider : $r('app.color.status_error') })
          .enterKeyType(EnterKeyType.Done)
          .accessibilityText($r('app.string.theme_hex'))
          .accessibilityDescription(THEME_HEX_FORMAT)
          .onChange((text: string): void => this.editHex(text))
        Text(THEME_HEX_FORMAT)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontColor(this.hexIsValid ? $r('sys.color.font_secondary') : $r('app.color.status_error'))
          .accessibilityLevel('no')
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').padding(SECTION_GAP).borderRadius(24).backgroundColor(this.appStyle.palette.cardBackground)
  }

  @Builder
  SaturationPad() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height('100%')
        .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], [Color.Black, 1]] })
      if (this.padWidth > 0) {
        Row().width(THEME_PAD_THUMB).height(THEME_PAD_THUMB)
          .borderRadius(THEME_PAD_THUMB / 2)
          .border({ width: 3, color: appearanceInk(this.draftSeed) })
          .backgroundColor(this.draftSeed)
          .position({
            x: Math.max(0, Math.min(this.padWidth - THEME_PAD_THUMB,
              this.hsvSaturation * this.padWidth - THEME_PAD_THUMB / 2)),
            y: Math.max(0, Math.min(THEME_PAD_HEIGHT - THEME_PAD_THUMB,
              (1 - this.hsvBrightness) * THEME_PAD_HEIGHT - THEME_PAD_THUMB / 2))
          })
      }
    }
    .width('100%').height(THEME_PAD_HEIGHT).direction(Direction.Ltr)
    .linearGradient({ direction: GradientDirection.Right, colors: [[Color.White, 0], [this.hueTint, 1]] })
    .borderRadius(8).clip(true)
    .accessibilityLevel('no-hide-descendants')
    // 色板子节点仅绘制；阻断父 Scroll / Sheet 对同一触点的拖动识别。
    .hitTestBehavior(HitTestMode.Block)
    .onSizeChange((_previous: SizeOptions, current: SizeOptions): void => { this.padWidth = Number(current.width); })
    .onTouch((event: TouchEvent): void => this.touchPad(event))
  }

  @Builder
  Sliders() {
    Column() {
      Row({ space: HEADER_GAP }) {
        Text($r('app.string.theme_hue')).fontFamily(this.appStyle.fontFamily).fontSize(14).width(82)
          .accessibilityLevel('no')
        Slider({ value: Math.round(this.hsvHue), min: 0, max: 360, step: 1 })
          .layoutWeight(1).height(48).direction(Direction.Ltr)
          .trackColor(this.hueTrack).selectedColor(Color.Transparent).blockColor(this.hueTint)
          .blockBorderWidth(2).blockBorderColor(appearanceInk(this.hueTint))
          .showTips(true).accessibilityText($r('app.string.theme_hue'))
          .onChange((next: number): void => {
            if (next !== Math.round(this.hsvHue)) {
              this.pickHsv(next, this.hsvSaturation, this.hsvBrightness);
            }
          })
      }
      Row({ space: HEADER_GAP }) {
        Text($r('app.string.theme_saturation')).fontFamily(this.appStyle.fontFamily).fontSize(14).width(82)
          .accessibilityLevel('no')
        Slider({ value: Math.round(this.hsvSaturation * 100), min: 0, max: 100, step: 1 })
          .layoutWeight(1).height(48)
          .selectedColor(this.appStyle.palette.brand).trackColor(this.appStyle.palette.track)
          .showTips(true).accessibilityText($r('app.string.theme_saturation'))
          .onChange((next: number): void => {
            if (next !== Math.round(this.hsvSaturation * 100)) {
              this.pickHsv(this.hsvHue, next / 100, this.hsvBrightness);
            }
          })
      }
      Row({ space: HEADER_GAP }) {
        Text($r('app.string.theme_value')).fontFamily(this.appStyle.fontFamily).fontSize(14).width(82)
          .accessibilityLevel('no')
        Slider({ value: Math.round(this.hsvBrightness * 100), min: 0, max: 100, step: 1 })
          .layoutWeight(1).height(48)
          .selectedColor(this.appStyle.palette.brand).trackColor(this.appStyle.palette.track)
          .showTips(true).accessibilityText($r('app.string.theme_value'))
          .onChange((next: number): void => {
            if (next !== Math.round(this.hsvBrightness * 100)) {
              this.pickHsv(this.hsvHue, this.hsvSaturation, next / 100);
            }
          })
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      this.Header()
      Scroll() {
        Column({ space: PAGE_GUTTER }) {
          this.PreviewAndHex()
          this.SaturationPad()
          this.Sliders()
        }
        .width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: SECTION_GAP, bottom: 20 })
      }
      .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
    }
    .width('100%').height('100%')
  }
}
