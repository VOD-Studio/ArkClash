import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';

const require = createRequire(import.meta.url);
const ts = require(process.env.ARKCLASH_TYPESCRIPT);
function loadComponent(file, imports = {}) {
  const source = readFileSync(new URL(`../entry/src/main/ets/components/${file}.ets`, import.meta.url), 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
  }).outputText;
  const exports = {};
  new Function('exports', 'require', 'ObservedV2', 'Trace', code)(exports, name => {
    assert.ok(name in imports, `unexpected import ${name}`);
    return imports[name];
  }, type => type, () => {});
  return exports;
}

const palette = loadComponent('AppearancePalette');
const { appearanceHex, appearancePalette, parseAppearanceHex } = palette;

async function appearanceFixture(flush, system = { dark: false }) {
  const prefs = {
    cached: '', stored: '', writes: 0,
    async get() { return this.cached; },
    async put(_key, value) { this.cached = value; },
    async flush() { await flush(++this.writes); this.stored = this.cached; }
  };
  const { AppearanceState } = loadComponent('AppearanceState', {
    './AppearancePalette': palette,
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: {
      COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1, COLOR_MODE_NOT_SET: -1
    } } },
    '@kit.ArkData': { preferences: { getPreferences: async () => prefs } },
    '@kit.ArkUI': {
      uiAppearance: { getFontScale: () => 1, getDarkMode: () => system.dark ? 0 : 1, DarkMode: { ALWAYS_DARK: 0 } },
      ThemeControl: { setDefaultTheme() {} },
      uiMaterial: { ImmersiveMaterial: class {}, ImmersiveStyle: {} }
    },
    '@kit.LocalizationKit': {
      resourceManager: { getSysResourceManager: () => ({ getColorByNameSync: () => palette.DEFAULT_APPEARANCE_SEED }) }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, error() {} } }
  });
  const state = new AppearanceState();
  await state.load({ config: {}, setColorMode() {} });
  return { prefs, state };
}

test('rapid theme selections merge in tap order and repeating the current value skips the write', async () => {
  let release;
  let entered;
  const gate = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const { state, prefs } = await appearanceFixture(async write => {
    if (write === 1) { entered(); await gate; }
  });
  const first = state.save(next => { next.motion = 'fade'; });
  await started;
  const dock = state.save(next => { next.floating = false; });
  const reverse = state.save(next => { next.motion = 'slide'; });
  const repeat = state.save(next => { next.motion = 'slide'; });
  assert.equal(state.motion, 'slide');
  assert.equal(prefs.writes, 1);
  release();
  await Promise.all([first, dock, reverse, repeat]);
  assert.equal(state.floating, false);
  assert.equal(state.motion, 'slide');
  assert.deepEqual(JSON.parse(prefs.stored), { ...state.config });
  assert.equal(prefs.writes, 3);
});

test('a failed theme save rolls back the swatches and the following selection still persists', async () => {
  const { state, prefs } = await appearanceFixture(async write => {
    if (write === 1) { throw new Error('flush failed'); }
  });
  const swatches = state.config.swatches.slice();
  const failed = state.save(next => { next.swatches.pop(); next.glass = 'ultra'; });
  const following = state.save(next => { next.motion = 'fade'; });
  await assert.rejects(failed, /flush failed/);
  await following;
  assert.deepEqual(state.config.swatches, swatches);
  assert.equal(state.glass, 'standard');
  assert.equal(state.motion, 'fade');
  assert.deepEqual(JSON.parse(prefs.stored), { ...state.config });
});

test('only effective light/dark changes transition, including a return to the current system appearance', async () => {
  const system = { dark: false };
  const { state } = await appearanceFixture(async () => {}, system);
  const transitions = [];
  state.colorModeTransition = apply => {
    const before = state.isDark;
    apply();
    transitions.push([before, state.isDark]);
  };
  const choose = mode => state.save(next => { next.mode = mode; });
  await choose('light');
  await choose('dark');
  state.updateSystem({ colorMode: 0 });
  await choose('system');
  assert.equal(state.isDark, false);
  system.dark = true;
  state.updateSystem({ colorMode: 0 });
  state.updateSystem({ colorMode: 0 });
  await choose('dark');
  system.dark = false;
  await choose('system');
  await state.save(next => { next.pureBlack = true; });
  assert.deepEqual(transitions, [[false, true], [true, false], [false, true], [true, false]]);
});

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
