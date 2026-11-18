import { LengthMetrics } from '@kit.ArkUI';
import { AppearanceColorStyle, AppearancePalette, appearanceHex, appearanceInk, appearancePalette,
  DEFAULT_APPEARANCE_SEED } from '../../components/AppearancePalette';
import { APPEARANCE_SWATCHES, AppearanceGlass, AppearanceMode, AppearanceMotion, AppearanceSettings,
  AppearanceState, appAppearance, TEXT_SCALE_MAX, TEXT_SCALE_MIN, TEXT_SCALE_STEP } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { uiResourceText } from '../../components/ResourceText';
import { CARD_RADIUS, PAGE_GUTTER } from '../../components/Theme';
import { ThemeColorEditor } from './ThemeColorEditor';
import { ThemeFonts } from './ThemeFonts';
import { ThemePreview } from './ThemePreview';

interface ThemePaintChoice {
  style: AppearanceColorStyle;
  label: Resource;
}

interface ThemeChoiceOptions {
  label: Resource;
  selected: boolean;
  action: () => void;
  colors: AppearancePalette;
  floating: boolean;
  glass: AppearanceGlass;
  other?: AppearancePalette;
}

interface ThemeHeadingOptions {
  label: Resource;
  action?: Resource;
  onTap?: () => void;
}

interface ThemeModeChoice {
  mode: AppearanceMode;
  label: Resource;
  colors: AppearancePalette;
  other?: AppearancePalette;
}

interface ThemeSwatchOptions {
  seed: number;
  fill: number;
}

const PAINT_CHOICES: ThemePaintChoice[] = [
  { style: 'vivid', label: $r('app.string.theme_vivid') }, { style: 'tinted', label: $r('app.string.theme_tinted') },
  { style: 'soft', label: $r('app.string.theme_soft') }, { style: 'monochrome', label: $r('app.string.theme_monochrome') }
];

type ThemeSheet = 'color' | 'delete' | 'reset' | 'fonts';

@ComponentV2
export struct ThemePage {
  @Param reduceMotion: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private previewTab: number = 0;
  @Local private previewX: number = 0;
  @Local private previewOpacity: number = 1;
  @Local private sheetOpen: boolean = false;
  @Local private sheet: ThemeSheet = 'color';
  @Local private colorTarget: number = 0;
  @Local private colorInitial: number = DEFAULT_APPEARANCE_SEED;
  @Local private scaleDraft: number = 0;
  @Local private styleMenuOpen: boolean = false;
  private pending?: AppearanceSettings;

  @Computed
  get lightPreview(): AppearancePalette {
    return appearancePalette(this.appStyle.seed, false, false, this.appStyle.config.style);
  }

  @Computed
  get darkPreview(): AppearancePalette {
    return appearancePalette(this.appStyle.seed, true, false, this.appStyle.config.style);
  }

  @Computed
  get blackPreview(): AppearancePalette {
    return appearancePalette(this.appStyle.seed, true, true, this.appStyle.config.style);
  }

  @Computed
  get displayedScale(): number {
    if (this.scaleDraft > 0) { return this.scaleDraft; }
    const scale = this.appStyle.config.customScale ? this.appStyle.config.scale : this.appStyle.systemScale;
    return Math.min(1.75, scale);
  }

  @Computed
  get defaultColors(): boolean {
    const config = this.appStyle.config;
    return config.seed === DEFAULT_APPEARANCE_SEED && config.style === 'vivid' &&
      config.swatches.length === APPEARANCE_SWATCHES.length &&
      config.swatches.every((seed: number, index: number): boolean => seed === APPEARANCE_SWATCHES[index]);
  }

  private change(update: (config: AppearanceSettings) => void): void {
    const config = this.appStyle.config.clone();
    update(config);
    this.save(config);
  }

  private async save(config: AppearanceSettings): Promise<void> {
    try {
      await this.appStyle.save(config);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.theme_save_failed') });
    }
  }

  private openSheet(sheet: ThemeSheet, seed: number = 0): void {
    this.pending = undefined;
    this.sheet = sheet;
    this.colorTarget = seed;
    this.colorInitial = seed || this.appStyle.seed;
    this.sheetOpen = true;
  }

  private saveColor(seed: number): void {
    const config = this.appStyle.config.clone();
    const previous = this.colorTarget;
    const index = config.swatches.indexOf(previous);
    if (previous === 0) {
      if (!config.swatches.includes(seed)) { config.swatches = config.swatches.concat(seed); }
      config.seed = seed;
    } else if (index >= 0 && seed !== previous) {
      config.swatches = config.swatches.slice();
      if (config.swatches.includes(seed)) { config.swatches.splice(index, 1); }
      else { config.swatches[index] = seed; }
      if (config.seed === previous) { config.seed = seed; }
    }
    this.pending = config;
    this.sheetOpen = false;
  }

  private confirmColors(): void {
    const config = this.appStyle.config.clone();
    if (this.sheet === 'reset') {
      config.seed = DEFAULT_APPEARANCE_SEED;
      config.swatches = APPEARANCE_SWATCHES.slice();
      config.style = 'vivid';
    } else {
      config.swatches = config.swatches.filter((seed: number): boolean => seed !== this.colorTarget);
      if (config.seed === this.colorTarget) {
        config.seed = config.swatches.includes(DEFAULT_APPEARANCE_SEED) ? DEFAULT_APPEARANCE_SEED : 0;
      }
    }
    this.pending = config;
    this.sheetOpen = false;
  }

  private finishSheet(): void {
    const pending = this.pending;
    this.pending = undefined;
    if (pending !== undefined) { this.save(pending); }
  }

  private preview(index: number, motion: AppearanceMotion = this.appStyle.motion): void {
    if (this.previewTab === index || this.reduceMotion) {
      this.previewTab = index;
      return;
    }
    const offset = index > this.previewTab ? 20 : -20;
    const ui = this.getUIContext();
    ui.animateTo({ duration: 0 }, () => {
      this.previewTab = index;
      this.previewOpacity = motion === 'fade' ? 0 : 1;
      this.previewX = motion === 'slide' ? offset : 0;
    });
    ui.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.previewOpacity = 1;
      this.previewX = 0;
    });
  }

  private changeScale(value: number, mode: SliderChangeMode): void {
    this.scaleDraft = value / 100;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      const scale = this.scaleDraft;
      this.scaleDraft = 0;
      if (scale !== this.appStyle.config.scale) {
        this.change((config: AppearanceSettings) => { config.scale = scale; });
      }
    }
  }

  @Builder
  HeaderTitle() { DestinationTitle({ titleText: $r('app.string.tools_theme') }) }

  @Builder
  Heading($$: ThemeHeadingOptions) {
    Row() {
      Text($$.label).fontSize(17).fontWeight(600).fontFamily(this.appStyle.fontFamily)
        .fontColor($r('sys.color.font_primary')).layoutWeight(1)
      if ($$.action !== undefined) {
        Button($$.action).fontFamily(this.appStyle.fontFamily).fontSize(13).height(40)
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.appStyle.palette.brand)
          .enabled(!this.appStyle.saving).onClick(() => $$.onTap?.())
      }
    }
    .width('100%').constraintSize({ minHeight: 40 })
  }

  @Builder
  Choice($$: ThemeChoiceOptions) {
    Button() {
      Column({ space: 6 }) {
        ThemePreview({ colors: $$.colors, otherColors: $$.other, floating: $$.floating, glass: $$.glass })
        Text($$.label).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($$.selected ? this.appStyle.palette.brand : $r('sys.color.font_primary'))
          .textAlign(TextAlign.Center)
      }
      .width('100%').padding(6)
    }
    .layoutWeight(1).padding(0).borderRadius(14).buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor($$.selected ? this.appStyle.palette.selectionTonal : this.appStyle.palette.cardBackground)
    .border({ width: 1.5, color: $$.selected ? this.appStyle.palette.brand : Color.Transparent })
    .accessibilityText(uiResourceText(this.getUIContext(), $$.label)).accessibilitySelected($$.selected)
    .enabled(!this.appStyle.saving).onClick(() => $$.action())
  }

  @Builder
  ModeChoice($$: ThemeModeChoice) {
    this.Choice({ label: $$.label, selected: this.appStyle.config.mode === $$.mode,
      action: () => this.change((config: AppearanceSettings) => { config.mode = $$.mode; }),
      colors: $$.colors, floating: this.appStyle.floating, glass: this.appStyle.glass, other: $$.other })
  }

  @Builder
  SwatchMenu(seed: number) {
    Menu() {
      MenuItem({ content: $r('app.string.theme_edit') }).onClick(() => this.openSheet('color', seed))
      MenuItem({ content: $r('app.string.theme_delete') }).onClick(() => this.openSheet('delete', seed))
    }
  }

  @Builder
  Swatch($$: ThemeSwatchOptions) {
    if ($$.seed === 0) {
      this.SwatchButton({ seed: $$.seed, fill: $$.fill })
    } else {
      Row() {
        this.SwatchButton({ seed: $$.seed, fill: $$.fill })
      }
      .bindContextMenu(this.SwatchMenu($$.seed), ResponseType.LongPress)
    }
  }

  @Builder
  SwatchButton($$: ThemeSwatchOptions) {
    Button({ type: ButtonType.Circle }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(32).height(32).fill($$.fill)
          .stroke(this.appStyle.palette.divider).strokeWidth(1)
        if (this.appStyle.config.seed === $$.seed) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([appearanceInk($$.fill)])
        } else if ($$.seed === 0) {
          Text('A').fontSize(15).fontWeight(600).fontColor(appearanceInk($$.fill))
        }
      }
      .width(36).height(36)
    }
    .width(44).height(44).padding(0).buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(Color.Transparent)
    .border({ width: 2, color: this.appStyle.config.seed === $$.seed ? $$.fill : Color.Transparent })
    .enabled(!this.appStyle.saving)
    .id($$.seed === 0 ? 'theme-swatch-system' : `theme-swatch-${appearanceHex($$.seed).slice(1)}`)
    .accessibilityText($$.seed === 0 ? uiResourceText(this.getUIContext(), $r('app.string.theme_system')) :
      appearanceHex($$.seed))
    .accessibilitySelected(this.appStyle.config.seed === $$.seed)
    .onClick(() => this.change((config: AppearanceSettings) => { config.seed = $$.seed; }))
  }

  @Builder
  ColorStyleMenu() {
    Menu() {
      ForEach(PAINT_CHOICES, (choice: ThemePaintChoice) => {
        MenuItem({ content: choice.label }).selected(this.appStyle.config.style === choice.style)
          .onClick(() => this.change((config: AppearanceSettings) => { config.style = choice.style; }))
      }, (choice: ThemePaintChoice): string => choice.style)
    }
  }

  private styleLabel(): Resource {
    return PAINT_CHOICES.find((choice: ThemePaintChoice): boolean => choice.style === this.appStyle.config.style)?.label ??
      PAINT_CHOICES[0].label;
  }

  @Builder
  ColorSection() {
    Column({ space: 8 }) {
      this.Heading({ label: $r('app.string.theme_color'),
        action: this.defaultColors ? undefined : $r('app.string.theme_reset'), onTap: () => this.openSheet('reset') })
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
        this.Swatch({ seed: 0, fill: this.appStyle.systemSeed })
        ForEach(this.appStyle.config.swatches, (seed: number) => {
          this.Swatch({ seed: seed, fill: seed })
        }, (seed: number): string => `${seed}`)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([this.appStyle.palette.brand])
        }
        .width(44).height(44).padding(0).buttonStyle(ButtonStyleMode.NORMAL)
        .backgroundColor(this.appStyle.palette.tileBackground)
        .id('theme-color-add').enabled(!this.appStyle.saving)
        .accessibilityText(uiResourceText(this.getUIContext(), $r('app.string.theme_add_color')))
        .onClick(() => this.openSheet('color'))
      }
      .padding(10).width('100%').borderRadius(CARD_RADIUS).backgroundColor(this.appStyle.palette.cardBackground)
      Button() {
        Row({ space: 8 }) {
          Text($r('app.string.theme_color_style')).layoutWeight(1).fontFamily(this.appStyle.fontFamily).fontSize(16)
          Text(this.styleLabel()).fontFamily(this.appStyle.fontFamily).fontSize(14).fontColor(this.appStyle.palette.brand)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('sys.color.icon_secondary')])
        }
        .width('100%')
      }
      .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16 })
      .borderRadius(CARD_RADIUS).buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(this.appStyle.palette.cardBackground)
      .enabled(!this.appStyle.saving).onClick(() => { this.styleMenuOpen = true; })
      .bindMenu(this.styleMenuOpen, this.ColorStyleMenu, { onDisappear: () => { this.styleMenuOpen = false; } })
    }
  }

  @Builder
  GlassChoice(level: AppearanceGlass, label: Resource) {
    this.Choice({ label: label, selected: this.appStyle.glass === level, floating: true, glass: level,
      colors: this.appStyle.palette,
      action: () => this.change((config: AppearanceSettings) => { config.glass = level; }) })
  }

  @Builder
  Typography() {
    Column({ space: 8 }) {
      this.Heading({ label: $r('app.string.theme_font') })
      Button() {
        Row({ space: 12 }) {
          Text('Aa').fontFamily(this.appStyle.fontFamily).fontSize(22).fontWeight(600)
          Text(this.appStyle.fontFamily || $r('app.string.theme_default')).fontFamily(this.appStyle.fontFamily)
            .fontSize(16).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.icon_secondary')])
        }
        .width('100%')
      }
      .width('100%').constraintSize({ minHeight: 56 }).buttonStyle(ButtonStyleMode.NORMAL).borderRadius(CARD_RADIUS)
      .backgroundColor(this.appStyle.palette.cardBackground).id('theme-font-open')
      .enabled(!this.appStyle.saving).onClick(() => this.openSheet('fonts'))
      this.Heading({ label: $r('app.string.theme_text_scale'), action:
        this.appStyle.config.customScale && this.appStyle.config.scale !== 1 ? $r('app.string.theme_reset') : undefined,
        onTap: () => this.change((config: AppearanceSettings) => { config.scale = 1; }) })
      Row({ space: 8 }) {
        this.ScaleMode($r('app.string.theme_system'), false)
        this.ScaleMode($r('app.string.theme_custom'), true)
      }
      .width('100%')
      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Text($r('app.string.theme_text_sample')).fontSize(`${18 * this.displayedScale}vp`)
            .fontFamily(this.appStyle.fontFamily).layoutWeight(1).fontColor($r('sys.color.font_primary'))
          Text(`${Math.round(this.displayedScale * 100)}%`).fontSize('14vp').fontFamily(this.appStyle.fontFamily)
            .fontColor(this.appStyle.palette.brand)
        }
        .width('100%')
        Slider({ value: Math.round(Math.max(TEXT_SCALE_MIN, Math.min(TEXT_SCALE_MAX, this.displayedScale)) * 100),
          min: TEXT_SCALE_MIN * 100,
          max: TEXT_SCALE_MAX * 100, step: TEXT_SCALE_STEP * 100 })
          .width('100%').selectedColor(this.appStyle.palette.brand).blockColor(this.appStyle.palette.brand)
          .accessibilityText(uiResourceText(this.getUIContext(), $r('app.string.theme_text_scale')))
          .enabled(this.appStyle.config.customScale && !this.appStyle.saving)
          .id('theme-text-scale').onChange((value: number, mode: SliderChangeMode) => this.changeScale(value, mode))
      }
      .padding(16).width('100%').borderRadius(CARD_RADIUS).backgroundColor(this.appStyle.palette.cardBackground)
    }
  }

  @Builder
  ScaleMode(label: Resource, custom: boolean) {
    Button(label).fontFamily(this.appStyle.fontFamily).layoutWeight(1).constraintSize({ minHeight: 44 })
      .buttonStyle(ButtonStyleMode.NORMAL)
      .fontColor(this.appStyle.config.customScale === custom ? this.appStyle.palette.brand : $r('sys.color.font_primary'))
      .backgroundColor(this.appStyle.config.customScale === custom ? this.appStyle.palette.selectionTonal :
        this.appStyle.palette.cardBackground)
      .accessibilitySelected(this.appStyle.config.customScale === custom).enabled(!this.appStyle.saving)
      .onClick(() => this.change((config: AppearanceSettings) => { config.customScale = custom; }))
  }

  @Builder
  SheetBody() {
    if (this.sheet === 'color') {
      ThemeColorEditor({ seed: this.colorInitial, pureBlack: this.appStyle.config.pureBlack,
        colorStyle: this.appStyle.config.style, onCancel: () => { this.sheetOpen = false; },
        onConfirm: (seed: number) => this.saveColor(seed) })
    } else if (this.sheet === 'fonts') {
      ThemeFonts({ onChoose: (family: string) => this.change((config: AppearanceSettings) => { config.font = family; }) })
    } else {
      Column({ space: 16 }) {
        Text(this.sheet === 'reset' ? $r('app.string.theme_reset_colors') : $r('app.string.theme_delete_color'))
          .fontSize(20).fontWeight(600).fontFamily(this.appStyle.fontFamily)
        if (this.sheet === 'delete') {
          Text(appearanceHex(this.colorTarget)).fontFamily(this.appStyle.fontFamily).fontSize(16)
        }
        Row({ space: 8 }) {
          Button($r('app.string.theme_cancel')).fontFamily(this.appStyle.fontFamily).layoutWeight(1)
            .constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.NORMAL)
            .onClick(() => { this.sheetOpen = false; })
          Button(this.sheet === 'reset' ? $r('app.string.theme_reset') : $r('app.string.theme_delete'))
            .fontFamily(this.appStyle.fontFamily).layoutWeight(1).constraintSize({ minHeight: 48 })
            .role(ButtonRole.ERROR).onClick(() => this.confirmColors())
        }
        .width('100%')
      }
      .padding(24).width('100%')
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          ThemePreview({ colors: this.appStyle.palette, floating: this.appStyle.floating, glass: this.appStyle.glass,
            compact: false, pageIndex: this.previewTab,
            onPreviewTab: (index: number) => this.preview(index) })
            .translate({ x: this.previewX }).opacity(this.previewOpacity)
          Column({ space: 8 }) {
            this.Heading({ label: $r('app.string.theme_mode') })
            Row({ space: 8 }) {
              this.ModeChoice({ mode: 'system', label: $r('app.string.theme_system'), colors: this.lightPreview,
                other: this.appStyle.config.pureBlack ? this.blackPreview : this.darkPreview })
              this.ModeChoice({ mode: 'light', label: $r('app.string.theme_light'), colors: this.lightPreview })
              this.ModeChoice({ mode: 'dark', label: $r('app.string.theme_dark'),
                colors: this.appStyle.config.pureBlack ? this.blackPreview : this.darkPreview })
            }
          }
          .width('100%')
          Column({ space: 8 }) {
            this.Heading({ label: $r('app.string.theme_pure_black_mode') })
            Row({ space: 8 }) {
              this.Choice({ label: $r('app.string.theme_standard'), selected: !this.appStyle.config.pureBlack,
                action: () => this.change((config: AppearanceSettings) => { config.pureBlack = false; }),
                colors: this.darkPreview, floating: this.appStyle.floating, glass: this.appStyle.glass })
              this.Choice({ label: $r('app.string.theme_pure_black'), selected: this.appStyle.config.pureBlack,
                action: () => this.change((config: AppearanceSettings) => { config.pureBlack = true; }),
                colors: this.blackPreview, floating: this.appStyle.floating, glass: this.appStyle.glass })
            }
          }
          .width('100%')
          this.ColorSection()
          Column({ space: 8 }) {
            this.Heading({ label: $r('app.string.theme_navigation') })
            Row({ space: 8 }) {
              this.Choice({ label: $r('app.string.theme_floating'), selected: this.appStyle.floating,
                action: () => this.change((config: AppearanceSettings) => { config.floating = true; }),
                colors: this.appStyle.palette, floating: true, glass: this.appStyle.glass })
              this.Choice({ label: $r('app.string.theme_docked'), selected: !this.appStyle.floating,
                action: () => this.change((config: AppearanceSettings) => { config.floating = false; }),
                colors: this.appStyle.palette, floating: false, glass: this.appStyle.glass })
            }
          }
          .width('100%')
          Column({ space: 8 }) {
            this.Heading({ label: $r('app.string.theme_tab_motion') })
            Row({ space: 8 }) {
              this.Choice({ label: $r('app.string.theme_slide'), selected: this.appStyle.motion === 'slide',
                colors: this.appStyle.palette, floating: this.appStyle.floating, glass: this.appStyle.glass,
                action: () => {
                  this.change((config: AppearanceSettings) => { config.motion = 'slide'; });
                  this.preview((this.previewTab + 1) % 4, 'slide');
                } })
              this.Choice({ label: $r('app.string.theme_fade'), selected: this.appStyle.motion === 'fade',
                colors: this.appStyle.palette, floating: this.appStyle.floating, glass: this.appStyle.glass,
                action: () => {
                  this.change((config: AppearanceSettings) => { config.motion = 'fade'; });
                  this.preview((this.previewTab + 1) % 4, 'fade');
                } })
            }
          }
          .width('100%')
          Column({ space: 8 }) {
            this.Heading({ label: $r('app.string.theme_glass') })
            Row({ space: 8 }) {
              this.GlassChoice('none', $r('app.string.theme_none'))
              this.GlassChoice('standard', $r('app.string.theme_standard'))
              this.GlassChoice('ultra', $r('app.string.theme_ultra'))
            }
          }
          .width('100%')
          this.Typography()
        }
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 32 }).width('100%')
        .constraintSize({ maxWidth: 640 })
      }
      .width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
      .bindSheet($$this.sheetOpen, this.SheetBody, {
        height: this.sheet === 'color' || this.sheet === 'fonts' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        preferType: SheetType.BOTTOM, showClose: this.sheet === 'fonts',
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, systemMaterial: this.appStyle.sheetMaterial(),
        backgroundColor: this.appStyle.palette.cardBackground, onDisappear: () => this.finishSheet()
      })
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }
}
