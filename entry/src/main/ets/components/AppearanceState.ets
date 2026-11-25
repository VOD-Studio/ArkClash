import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ThemeControl, uiAppearance, uiMaterial } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppearanceColorStyle, AppearancePalette, appearancePalette, DEFAULT_APPEARANCE_SEED } from './AppearancePalette';

export type AppearanceMode = 'system' | 'light' | 'dark';
export type AppearanceMotion = 'slide' | 'fade';
export type AppearanceGlass = 'none' | 'standard' | 'ultra';

export const APPEARANCE_SWATCHES: number[] = [
  DEFAULT_APPEARANCE_SEED, 0xFFCB30E0, 0xFFFF2D55, 0xFFFF383C, 0xFFFF8D28, 0xFFFFCC00, 0xFF34C759, 0xFF8E8E93
];
export const TEXT_SCALE_MIN = 0.8;
export const TEXT_SCALE_MAX = 1.4;
export const TEXT_SCALE_STEP = 0.05;

export class AppearanceSettings {
  mode: AppearanceMode = 'system';
  pureBlack: boolean = false;
  seed: number = DEFAULT_APPEARANCE_SEED;
  swatches: number[];
  style: AppearanceColorStyle = 'vivid';
  floating: boolean = true;
  motion: AppearanceMotion = 'slide';
  glass: AppearanceGlass = 'standard';
  font: string = '';
  customScale: boolean = false;
  scale: number = 1;

  constructor(swatches: number[] = APPEARANCE_SWATCHES.slice()) {
    this.swatches = swatches;
  }

  clone(): AppearanceSettings {
    const copy = new AppearanceSettings(this.swatches.slice());
    copy.mode = this.mode;
    copy.pureBlack = this.pureBlack;
    copy.seed = this.seed;
    copy.style = this.style;
    copy.floating = this.floating;
    copy.motion = this.motion;
    copy.glass = this.glass;
    copy.font = this.font;
    copy.customScale = this.customScale;
    copy.scale = this.scale;
    return copy;
  }
}

function validSeed(value: number): boolean {
  return Number.isInteger(value) && value >= 0xFF000000 && value <= 0xFFFFFFFF;
}

function decodeAppearance(text: string): AppearanceSettings {
  const raw = JSON.parse(text) as Record<string, Object>;
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error('invalid appearance settings');
  }
  const config = new AppearanceSettings();
  const mode = raw['mode'];
  if (mode === 'light' || mode === 'dark') { config.mode = mode as AppearanceMode; }
  const style = raw['style'];
  if (style === 'soft' || style === 'monochrome' || style === 'tinted') { config.style = style as AppearanceColorStyle; }
  if (Array.isArray(raw['swatches'])) {
    const entries = raw['swatches'] as number[];
    config.swatches = Array.from(new Set<number>(entries.filter((color: number) => validSeed(color))));
  }
  const seed = raw['seed'];
  if (typeof seed === 'number') {
    config.seed = seed === 0 || config.swatches.includes(seed) ? seed : 0;
  }
  config.pureBlack = raw['pureBlack'] === true;
  config.floating = raw['floating'] !== false;
  config.motion = raw['motion'] === 'fade' ? 'fade' : 'slide';
  const glass = raw['glass'];
  if (glass === 'none' || glass === 'ultra') { config.glass = glass as AppearanceGlass; }
  if (typeof raw['font'] === 'string') { config.font = raw['font'] as string; }
  config.customScale = raw['customScale'] === true;
  const scale = raw['scale'];
  if (typeof scale === 'number' && Number.isFinite(scale) && scale >= TEXT_SCALE_MIN && scale <= TEXT_SCALE_MAX) {
    config.scale = scale;
  }
  return config;
}

const PREF_KEY = 'appearance';
const DOMAIN = 0x0A11;
const TAG = 'Appearance';
const DARK = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
const LIGHT = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
const SYSTEM = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
const STANDARD_HEADER = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN, interactive: true, lightEffect: {}
});
const ULTRA_HEADER = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.ULTRA_THIN, interactive: true, lightEffect: {}
});
const STANDARD_SHEET = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK });
const ULTRA_SHEET = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
const STANDARD_REGULAR = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR });

@ObservedV2
export class AppearanceState {
  @Trace config: AppearanceSettings = new AppearanceSettings();
  @Trace palette: AppearancePalette = appearancePalette(DEFAULT_APPEARANCE_SEED, false, false, 'vivid');
  @Trace dark: boolean = false;
  @Trace fontFamily: string = '';
  @Trace floating: boolean = true;
  @Trace motion: AppearanceMotion = 'slide';
  @Trace glass: AppearanceGlass = 'standard';
  @Trace systemSeed: number = DEFAULT_APPEARANCE_SEED;
  @Trace systemScale: number = 1;
  private updates: Promise<void> = Promise.resolve();
  private prefs?: preferences.Preferences;
  private context?: common.UIAbilityContext;
  private lastSeed: number = DEFAULT_APPEARANCE_SEED;
  private lastDark: boolean = false;
  private lastPure: boolean = false;
  private lastStyle: AppearanceColorStyle = 'vivid';
  private overridesFontScale: boolean = false;

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const result = this.updates.then(operation);
    this.updates = result.catch((): void => {});
    return result;
  }

  load(context: common.UIAbilityContext): Promise<void> {
    return this.enqueue(() => this.read(context));
  }

  private async read(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.overridesFontScale = false;
    this.systemScale = context.config.fontSizeScale || 1;
    try {
      this.systemScale = uiAppearance.getFontScale();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'System font scale unavailable: %{public}s', (e as Error).message);
    }
    this.updateSystem(context.config);
    try {
      this.prefs = await preferences.getPreferences(context, { name: 'appearance' });
      const raw = await this.prefs.get(PREF_KEY, '');
      if (typeof raw === 'string' && raw !== '') {
        this.apply(decodeAppearance(raw));
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Could not load appearance: %{public}s', (e as Error).message);
    }
  }

  updateSystem(config: Configuration): void {
    if (config.colorMode !== undefined) { this.dark = config.colorMode === DARK; }
    try {
      const color = resourceManager.getSysResourceManager().getColorByNameSync('ohos_id_color_emphasize');
      this.systemSeed = (color | 0xFF000000) >>> 0;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'System accent unavailable: %{public}s', (e as Error).message);
    }
    this.updatePalette();
  }

  updateSystemFontScale(scale: number): void {
    if (!Number.isFinite(scale) || scale <= 0 || scale === this.systemScale) { return; }
    this.systemScale = scale;
    // 应用覆盖过字号后，框架不再自动跟随系统；系统配置监听仍提供原始值。
    if (this.overridesFontScale && !this.config.customScale) {
      this.context?.getApplicationContext().setFontSizeScale(scale);
    }
  }

  save(update: (config: AppearanceSettings) => void): Promise<void> {
    return this.enqueue(() => this.persist(update));
  }

  private async persist(update: (config: AppearanceSettings) => void): Promise<void> {
    const context = this.context;
    if (context === undefined) { throw new Error('appearance context unavailable'); }
    const next = this.config.clone();
    update(next);
    const previous = JSON.stringify(this.config);
    const encoded = JSON.stringify(next);
    if (encoded === previous) { return; }
    const prefs = this.prefs ?? await preferences.getPreferences(context, { name: 'appearance' });
    this.prefs = prefs;
    await prefs.put(PREF_KEY, encoded);
    try {
      await prefs.flush();
    } catch (e) {
      await prefs.put(PREF_KEY, previous);
      throw e as Error;
    }
    this.apply(next);
  }

  get seed(): number { return this.config.seed || this.systemSeed; }

  get isDark(): boolean {
    return this.config.mode === 'system' ? this.dark : this.config.mode === 'dark';
  }

  headerMaterial(): uiMaterial.Material {
    if (this.glass === 'none') { return uiMaterial.Material.empty; }
    return this.glass === 'ultra' ? ULTRA_HEADER : STANDARD_HEADER;
  }

  sheetMaterial(): uiMaterial.Material {
    if (this.glass === 'none') { return uiMaterial.Material.empty; }
    return this.glass === 'ultra' ? ULTRA_SHEET : STANDARD_SHEET;
  }

  regularMaterial(): uiMaterial.Material {
    if (this.glass === 'none') { return uiMaterial.Material.empty; }
    return this.glass === 'ultra' ? ULTRA_SHEET : STANDARD_REGULAR;
  }

  private apply(next: AppearanceSettings): void {
    const previous = this.config;
    this.config = next;
    this.fontFamily = next.font;
    this.floating = next.floating;
    this.motion = next.motion;
    this.glass = next.glass;
    if (previous.mode !== next.mode) {
      this.context?.setColorMode(next.mode === 'system' ? SYSTEM : next.mode === 'dark' ? DARK : LIGHT);
    }
    if (previous.customScale !== next.customScale || (next.customScale && previous.scale !== next.scale)) {
      this.overridesFontScale = true;
      this.context?.getApplicationContext().setFontSizeScale(next.customScale ? next.scale : this.systemScale);
    }
    this.updatePalette();
  }

  private updatePalette(): void {
    const config = this.config;
    const seed = this.seed;
    const dark = this.isDark;
    const pure = dark && config.pureBlack;
    if (seed === this.lastSeed && dark === this.lastDark && pure === this.lastPure && config.style === this.lastStyle) {
      return;
    }
    this.lastSeed = seed;
    this.lastDark = dark;
    this.lastPure = pure;
    this.lastStyle = config.style;
    const palette = appearancePalette(seed, dark, pure, config.style);
    this.palette = palette;
    ThemeControl.setDefaultTheme({ colors: {
      brand: palette.brand, fontOnPrimary: palette.onBrand, compBackgroundEmphasize: palette.brand,
      interactiveActive: palette.brand, iconEmphasize: palette.brand, fontEmphasize: palette.brand
    } });
  }
}

export const appAppearance: AppearanceState = new AppearanceState();
