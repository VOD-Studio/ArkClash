import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
const source = readFileSync(new URL('../entry/src/main/ets/components/AppearancePalette.ets', import.meta.url), 'utf8');
const loaded = { exports: {} };
new Function('exports', ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText)(loaded.exports);
const { appearanceHex, appearancePalette, parseAppearanceHex } = loaded.exports;

function lum(argb) {
  const channel = (shift) => {
    const s = ((argb >>> shift) & 255) / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

function contrast(a, b) {
  const x = lum(a) + 0.05;
  const y = lum(b) + 0.05;
  return Math.max(x, y) / Math.min(x, y);
}

function blend(bg, fg) {
  const alpha = (fg >>> 24) / 255;
  const channel = (shift) => Math.round(((bg >>> shift) & 255) * (1 - alpha) + ((fg >>> shift) & 255) * alpha);
  return 0xFF000000 + (channel(16) << 16) + (channel(8) << 8) + channel(0);
}

const styles = ['vivid', 'tinted', 'soft', 'monochrome'];
const seeds = ['#000000', '#FFFFFF', '#FFFF00', '#0000FF', '#00FF00', '#FF0033', '#CB30E0', '#007AFF'];

test('custom hex accepts only six color digits and canonicalizes the displayed swatch', () => {
  assert.equal(appearanceHex(parseAppearanceHex('  01a2F3  ')), '#01A2F3');
  assert.equal(parseAppearanceHex('#000000'), 0xFF000000);
  for (const bad of ['', '##012345', '#123', '#00ffffff', '123456x', '1234 56', 'gggggg']) {
    assert.equal(parseAppearanceHex(bad), undefined, bad);
  }
});

test('even extreme seeds keep selection labels and filled buttons legible', () => {
  for (const seed of seeds) {
    for (const style of styles) {
      for (const [dark, black] of [[false, false], [true, false], [true, true]]) {
        const palette = appearancePalette(parseAppearanceHex(seed), dark, black, style);
        const where = `${seed} ${style} dark=${dark} black=${black}`;
        assert.ok(contrast(palette.brand, palette.onBrand) >= 4.5, where);
        assert.ok(contrast(palette.brand, palette.pageBackground) >= 4.5, where);
        assert.ok(contrast(palette.brand, blend(palette.cardBackground, palette.profileExpiryTonal)) >= 4.5, where);
      }
    }
  }
});

test('pure black changes only dark surfaces without flattening the cards', () => {
  for (const style of styles) {
    const seed = parseAppearanceHex('#FF0033');
    const light = appearancePalette(seed, false, false, style);
    const black = appearancePalette(seed, true, true, style);
    const dark = appearancePalette(seed, true, false, style);
    assert.deepEqual(appearancePalette(seed, false, true, style), light);
    assert.equal(black.pageBackground, 0xFF000000);
    assert.ok(lum(black.cardBackground) > lum(black.pageBackground));
    assert.ok(lum(black.cardBackground) < lum(dark.cardBackground));
    assert.ok(lum(black.tileBackground) > lum(black.cardBackground));
  }
});

test('tinted changes surface hue, soft changes accent, and monochrome removes hue', () => {
  const seed = parseAppearanceHex('#00FF00');
  const palette = (style) => appearancePalette(seed, false, false, style);
  assert.notEqual(palette('vivid').pageBackground, palette('tinted').pageBackground);
  assert.notEqual(palette('vivid').brand, palette('soft').brand);
  for (const color of [palette('monochrome').brand, palette('monochrome').cardBackground]) {
    assert.equal((color >>> 16) & 255, color & 255);
    assert.equal((color >>> 8) & 255, color & 255);
  }
});
