export type AppearanceColorStyle = 'vivid' | 'tinted' | 'soft' | 'monochrome';

export interface AppearancePalette {
  readonly brand: number;
  readonly onBrand: number;
  readonly brandSoft: number;
  readonly brandPulse: number;
  readonly pageBackground: number;
  readonly cardBackground: number;
  readonly tileBackground: number;
  readonly surfaceBlock: number;
  readonly proxyNodeBackground: number;
  readonly selectionTonal: number;
  readonly dashSeriesSecondary: number;
  readonly dashAddableBackground: number;
  readonly dashStatusDecoration: number;
  readonly dashStatusIdleDecoration: number;
  readonly profileExpiryTonal: number;
  readonly memoryUi: number;
  readonly divider: number;
  readonly track: number;
  readonly proxyPressFeedback: number;
  readonly idleSoft: number;
}

interface AppearanceLab {
  lightness: number;
  a: number;
  b: number;
}

const BLACK: number = 0xFF000000;
const WHITE: number = 0xFFFFFFFF;
const RGB_MASK: number = 0x00FFFFFF;
const HEX = new RegExp('^#?[0-9a-fA-F]{6}$');
const SMALL_TEXT_CONTRAST: number = 4.5;
const PROFILE_TONAL_ALPHA: number = 0.15;
const SELECTION_TONAL_ALPHA: number = 0.14;
const DARK_PAGE_LIGHTNESS: number = 0.188;
// Prism 的深色背景色调为 L* 6；其余表面减去这 6 个色调单位，不一律刷黑。
const PURE_BLACK_SHIFT: number = 6 / 116;

export const DEFAULT_APPEARANCE_SEED: number = 0xFF007AFF;

export function appearanceHex(color: number): string {
  return '#' + (color & RGB_MASK).toString(16).padStart(6, '0').toUpperCase();
}

export function parseAppearanceHex(value: string): number | undefined {
  const text = value.trim();
  if (!HEX.test(text)) {
    return undefined;
  }
  return BLACK + parseInt(text.startsWith('#') ? text.slice(1) : text, 16);
}

function channel(color: number, shift: number): number {
  return (color >>> shift) & 0xFF;
}

function withAlpha(color: number, alpha: number): number {
  return Math.round(alpha * 255) * 0x1000000 + (color & RGB_MASK);
}

function linear(channelByte: number): number {
  const encoded = channelByte / 255;
  return encoded <= 0.04045 ? encoded / 12.92 : Math.pow((encoded + 0.055) / 1.055, 2.4);
}

function luminance(color: number): number {
  return 0.2126 * linear(channel(color, 16)) + 0.7152 * linear(channel(color, 8)) + 0.0722 * linear(channel(color, 0));
}

// 按不透明色块选字色；半透明颜色需由调用方先确定衬底。
export function appearanceInk(color: number): number {
  const light = luminance(color) + 0.05;
  return light * light >= 1.05 * 0.05 ? BLACK : WHITE;
}

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

function cube(value: number): number {
  return value * value * value;
}

function srgbByte(value: number): number {
  const bounded = clamp(value, 0, 1);
  const encoded = bounded <= 0.0031308 ? 12.92 * bounded : 1.055 * Math.pow(bounded, 1 / 2.4) - 0.055;
  return Math.round(255 * encoded);
}

function pack(red: number, green: number, blue: number): number {
  return BLACK + (red << 16) + (green << 8) + blue;
}

function blend(background: number, foreground: number, alpha: number): number {
  const base = 1 - alpha;
  return pack(Math.round(base * channel(background, 16) + alpha * channel(foreground, 16)),
    Math.round(base * channel(background, 8) + alpha * channel(foreground, 8)),
    Math.round(base * channel(background, 0) + alpha * channel(foreground, 0)));
}

// Oklab 的 a、b 同比例缩放，等同于沿 OKLCH 原色相调整彩度，无需三角函数。
function seedLab(seed: number): AppearanceLab {
  const red = linear(channel(seed, 16));
  const green = linear(channel(seed, 8));
  const blue = linear(channel(seed, 0));
  const l = Math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
  const m = Math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
  const s = Math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);
  return {
    lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  };
}

function inGamut(value: number): boolean {
  return value >= -0.000001 && value <= 1.000001;
}

function tryOklab(lightness: number, a: number, b: number): number {
  const l = cube(lightness + 0.3963377774 * a + 0.2158037573 * b);
  const m = cube(lightness - 0.1055613458 * a - 0.0638541728 * b);
  const s = cube(lightness - 0.0894841775 * a - 1.2914855480 * b);
  const red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
  return inGamut(red) && inGamut(green) && inGamut(blue) ? pack(srgbByte(red), srgbByte(green), srgbByte(blue)) : -1;
}

function gray(lightness: number): number {
  const tone = srgbByte(cube(lightness));
  return pack(tone, tone, tone);
}

function oklab(lightness: number, a: number, b: number): number {
  if (a === 0 && b === 0) {
    return gray(lightness);
  }
  const exact = tryOklab(lightness, a, b);
  if (exact >= 0) {
    return exact;
  }
  // 超出 sRGB 时先收彩度，逐通道截断会把极亮或极深主题色转成另一种色相。
  let low = 0;
  let high = 1;
  let best = gray(lightness);
  for (let step = 0; step < 8; step++) {
    const scale = (low + high) / 2;
    const candidate = tryOklab(lightness, a * scale, b * scale);
    if (candidate >= 0) {
      low = scale;
      best = candidate;
    } else {
      high = scale;
    }
  }
  return best;
}

function foregroundReadable(accent: number, surfaceLuminance: number, card: number, alpha: number,
  dark: boolean): boolean {
  const ink = luminance(accent) + 0.05;
  const tonal = luminance(blend(card, accent, alpha));
  const backing = (dark ? Math.max(surfaceLuminance, tonal) : Math.min(surfaceLuminance, tonal)) + 0.05;
  return (dark ? ink / backing : backing / ink) >= SMALL_TEXT_CONTRAST;
}

function accentColor(seed: number, lab: AppearanceLab, chroma: number, style: AppearanceColorStyle,
  dark: boolean, surfaceLuminance: number, card: number, alpha: number): number {
  if (style === 'monochrome') {
    return dark ? WHITE : BLACK;
  }
  const soft = style === 'soft';
  const scale = chroma === 0 ? 0 : soft ? Math.min(0.45, 0.075 / chroma) : 1;
  const a = lab.a * scale;
  const b = lab.b * scale;
  const lightness = soft ? (dark ? 0.78 : 0.53) : clamp(lab.lightness, dark ? 0.57 : 0.45, dark ? 0.83 : 0.70);
  const initial = !soft && lightness === lab.lightness ? seed : oklab(lightness, a, b);
  if (foregroundReadable(initial, surfaceLuminance, card, alpha, dark)) {
    return initial;
  }
  // 品牌色也用于小号文字（如配置有效期）；对比不够时才向可读的一端移动。
  let readable = dark ? 0.83 : 0.45;
  let unreadable = lightness;
  let best = oklab(readable, a, b);
  for (let step = 0; step < 8; step++) {
    const middle = (unreadable + readable) / 2;
    const candidate = oklab(middle, a, b);
    if (foregroundReadable(candidate, surfaceLuminance, card, alpha, dark)) {
      readable = middle;
      best = candidate;
    } else {
      unreadable = middle;
    }
  }
  return best;
}

export function appearancePalette(seed: number, dark: boolean, pureBlack: boolean,
  style: AppearanceColorStyle): AppearancePalette {
  const solidSeed = BLACK + (seed & RGB_MASK);
  const lab = seedLab(solidSeed);
  const seedChroma = Math.sqrt(lab.a * lab.a + lab.b * lab.b);
  const chroma = seedChroma < 0.00001 ? 0 : seedChroma;
  const surfaceScale = style === 'monochrome' || chroma === 0 ? 0 :
    style === 'tinted' ? Math.min(1 / 6, 0.038 / chroma) : Math.min(1 / 30, 0.008 / chroma);
  const a = lab.a * surfaceScale;
  const b = lab.b * surfaceScale;
  const paper = style === 'tinted' ? 1 : 0.5;
  const pageLightness = dark ? DARK_PAGE_LIGHTNESS : 0.949;
  const cardLightness = dark ? 0.268 : 0.983;
  const insetLightness = dark ? 0.372 : 0.900;
  const normalCard = oklab(cardLightness, a * (dark ? 1 : paper), b * (dark ? 1 : paper));
  const normalInset = oklab(insetLightness, a, b);
  const softAlpha = dark ? 0.16 : 0.10;
  const tonalAlpha = Math.round(Math.max(softAlpha, PROFILE_TONAL_ALPHA) * 255) / 255;
  const brand = accentColor(solidSeed, lab, chroma, style, dark, luminance(normalInset), normalCard, tonalAlpha);

  const black = dark && pureBlack;
  const shift = black ? PURE_BLACK_SHIFT : 0;
  const card = black ? oklab(cardLightness - shift, a, b) : normalCard;
  const inset = black ? oklab(insetLightness - shift, a, b) : normalInset;
  const neutralInk = dark ? WHITE : BLACK;
  const quietInk = withAlpha(neutralInk, dark ? 0.12 : 0.08);

  return {
    brand,
    onBrand: appearanceInk(brand),
    brandSoft: withAlpha(brand, softAlpha),
    brandPulse: withAlpha(brand, 0.35),
    pageBackground: black ? BLACK : oklab(pageLightness, a, b),
    cardBackground: card,
    tileBackground: oklab((dark ? 0.333 : 0.941) - shift, a, b),
    surfaceBlock: oklab((dark ? 0.322 : 0.935) - shift, a, b),
    proxyNodeBackground: oklab((dark ? 0.300 : 0.955) - shift, a, b),
    selectionTonal: withAlpha(brand, SELECTION_TONAL_ALPHA),
    dashSeriesSecondary: blend(card, brand, 0.45),
    dashAddableBackground: oklab((dark ? 0.240 : 0.971) - shift, a, b),
    dashStatusDecoration: blend(inset, brand, dark ? 0.22 : 0.18),
    dashStatusIdleDecoration: inset,
    profileExpiryTonal: withAlpha(brand, PROFILE_TONAL_ALPHA),
    memoryUi: blend(card, brand, 0.55),
    divider: withAlpha(neutralInk, 0.14),
    track: quietInk,
    proxyPressFeedback: withAlpha(neutralInk, 0.10),
    idleSoft: quietInk
  };
}
