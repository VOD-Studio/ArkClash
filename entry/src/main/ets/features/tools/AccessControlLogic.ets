import {
  MAX_VPN_EXCLUDED_APPS, MAX_VPN_TRUSTED_APPS, parseBundleImportText, vpnAccessEffectiveEqual, VpnAppAccessMode,
  VpnNetworkSettings
} from '../../shared/VpnNetwork';
import { ACCESS_CONTROL_CATALOG, AccessAppCategory, AccessCatalogEntry } from './AccessControlCatalog';

/** 列表里的一行：add 是「添加应用」首行，app 是应用，label 是分组小标题，empty 是搜索无结果。 */
export type AccessEntryKind = 'add' | 'app' | 'label' | 'empty';
/** label 行的含义：common =「常用应用」，results =「N 个结果」。 */
export type AccessLabelKind = 'common' | 'results';
export type AccessActiveMode = 'blocked' | 'trusted';

// 目录外应用拿不到图标，按包名散列到一组柔和底色 + 深色字，和目录内的品牌色方块区分开。
const GENERATED_ICON_TONES: string[][] = [
  ['#E0E7FF', '#4338CA'], ['#DCFCE7', '#15803D'], ['#FEF3C7', '#B45309'],
  ['#FCE7F3', '#BE185D'], ['#E0F2FE', '#0369A1'], ['#EDE9FE', '#6D28D9']
];
// 浅色品牌底（如美团黄）上白字不可读，改用深色字。
const LIGHT_BRAND_INK = '#161823';

export class AccessListEntry {
  readonly key: string;
  readonly kind: AccessEntryKind;
  readonly bundleName: string;
  readonly title: string;
  readonly containerNote: boolean;
  readonly iconColor: string;
  readonly iconInk: string;
  readonly iconText: string;
  readonly labelKind: AccessLabelKind;
  readonly count: number;
  // 同一张卡片的首尾行负责圆角。
  readonly first: boolean;
  readonly last: boolean;

  constructor(kind: AccessEntryKind, bundleName: string, title: string, containerNote: boolean, iconColor: string,
    iconInk: string, iconText: string, labelKind: AccessLabelKind, count: number, first: boolean, last: boolean) {
    this.kind = kind;
    this.bundleName = bundleName;
    this.title = title;
    this.containerNote = containerNote;
    this.iconColor = iconColor;
    this.iconInk = iconInk;
    this.iconText = iconText;
    this.labelKind = labelKind;
    this.count = count;
    this.first = first;
    this.last = last;
    // 首尾标记变化时换 key，行会重建并拿到正确的圆角。
    this.key = `${kind}:${bundleName}:${labelKind}:${first ? 1 : 0}${last ? 1 : 0}`;
  }

  withEdges(first: boolean, last: boolean): AccessListEntry {
    return new AccessListEntry(this.kind, this.bundleName, this.title, this.containerNote, this.iconColor,
      this.iconInk, this.iconText, this.labelKind, this.count, first, last);
  }
}

export interface AccessControlImportOutcome {
  ok: boolean;
  error: string;
  addedCount: number;
  totalCount: number;
  invalidCount: number;
  skippedOwn: boolean;
}

/** 单个名单相对已保存设置的增删数；mode 指名单所属模式（blocked 或 trusted）。 */
export interface AccessListChange {
  mode: VpnAppAccessMode;
  added: number;
  removed: number;
}

/** 离开确认页展示的修改摘要：开关或模式变化，以及当前模式名单的增删。 */
export interface AccessControlChanges {
  fromMode: VpnAppAccessMode;
  toMode: VpnAppAccessMode;
  lists: AccessListChange[];
}

/** 系统应用选择器返回的单个应用；label 可能为空串。 */
export interface AccessPickedApp {
  bundleName: string;
  label: string;
}

function listChange(mode: VpnAppAccessMode, before: string[], after: string[]): AccessListChange {
  const old = new Set<string>(before);
  const next = new Set<string>(after);
  return {
    mode: mode,
    added: Array.from(next).filter((item: string): boolean => !old.has(item)).length,
    removed: Array.from(old).filter((item: string): boolean => !next.has(item)).length
  };
}

function sameBundleSet(left: string[], right: string[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  const entries = new Set<string>(left);
  return entries.size === right.length && right.every((item: string): boolean => entries.has(item));
}

function entryMatchesQuery(bundleName: string, entry: AccessCatalogEntry | undefined, words: string[],
  label: string = ''): boolean {
  if (words.length === 0) {
    return true;
  }
  const haystack = entry === undefined ? `${label} ${bundleName}`.toLowerCase() :
    `${entry.nameZh} ${entry.nameEn} ${entry.bundleName} ${entry.keywords.join(' ')}`.toLowerCase();
  return words.every((word: string): boolean => haystack.includes(word));
}

function brandInk(color: string): string {
  const value = parseInt(color.slice(1), 16);
  const red = (value >> 16) & 0xFF;
  const green = (value >> 8) & 0xFF;
  const blue = value & 0xFF;
  return 0.299 * red + 0.587 * green + 0.114 * blue > 186 ? LIGHT_BRAND_INK : '#FFFFFF';
}

function generatedTone(bundleName: string): string[] {
  let hash = 0;
  for (let index = 0; index < bundleName.length; index++) {
    hash = (hash * 31 + bundleName.charCodeAt(index)) % 1000003;
  }
  return GENERATED_ICON_TONES[hash % GENERATED_ICON_TONES.length];
}

/** 名单为空时选「绕过所选」：开启后什么都不绕过，等于没变；空的「仅代理所选」无法保存。 */
function inferActiveMode(settings: VpnNetworkSettings): AccessActiveMode {
  if (settings.appAccessMode === 'blocked' || settings.appAccessMode === 'trusted') {
    return settings.appAccessMode;
  }
  return settings.trustedApplications.length > 0 && settings.excludedApplications.length === 0 ? 'trusted' : 'blocked';
}

/** 访问控制草稿：开关 + 两种模式，各自一份名单；打开或切换模式时快照已选项，勾选不跳行。 */
export class AccessControlDraft {
  private readonly baseline: VpnNetworkSettings;
  mode: VpnAppAccessMode;
  // 开关关掉时记住上次的模式，再打开时恢复。
  activeMode: AccessActiveMode;
  excluded: string[];
  trusted: string[];
  private pinnedOnOpen: string[];
  // 目录外应用的显示名，来自系统应用选择器；只影响显示和搜索，不参与脏检查。
  readonly labels: Map<string, string>;

  constructor(initial: VpnNetworkSettings, labels: Map<string, string> = new Map<string, string>()) {
    this.baseline = initial.copy();
    this.mode = initial.appAccessMode;
    this.activeMode = inferActiveMode(initial);
    this.excluded = initial.excludedApplications.slice();
    this.trusted = initial.trustedApplications.slice();
    this.pinnedOnOpen = this.listOf(this.activeMode).slice();
    this.labels = new Map<string, string>(labels);
  }

  enabled(): boolean {
    return this.mode !== 'off';
  }

  private listOf(mode: AccessActiveMode): string[] {
    return mode === 'trusted' ? this.trusted : this.excluded;
  }

  activeList(): string[] {
    return this.mode === 'off' ? [] : this.listOf(this.activeMode);
  }

  activeLimit(): number {
    if (this.mode === 'off') {
      return 0;
    }
    return this.activeMode === 'trusted' ? MAX_VPN_TRUSTED_APPS : MAX_VPN_EXCLUDED_APPS;
  }

  /** 当前模式还能再选几个，用作系统选择器的单次上限参考。 */
  activeRemaining(): number {
    return Math.max(0, this.activeLimit() - this.activeList().length);
  }

  private setActiveList(next: string[]): void {
    if (this.mode === 'off') {
      return;
    }
    if (this.activeMode === 'trusted') {
      this.trusted = next;
    } else {
      this.excluded = next;
    }
  }

  setEnabled(on: boolean): void {
    if (on === this.enabled()) {
      return;
    }
    this.mode = on ? this.activeMode : 'off';
    this.pinnedOnOpen = this.listOf(this.activeMode).slice();
  }

  setMode(next: AccessActiveMode): void {
    if (this.activeMode === next && this.mode === next) {
      return;
    }
    this.activeMode = next;
    this.mode = next;
    this.pinnedOnOpen = this.listOf(next).slice();
  }

  isSelected(bundleName: string): boolean {
    return this.activeList().includes(bundleName);
  }

  toggle(bundleName: string): string {
    if (this.mode === 'off') {
      return '';
    }
    const current = this.activeList();
    if (current.includes(bundleName)) {
      this.setActiveList(current.filter((item: string): boolean => item !== bundleName));
      return '';
    }
    if (current.length >= this.activeLimit()) {
      return 'too_many_apps';
    }
    this.setActiveList(current.concat([bundleName]));
    return '';
  }

  /** 仅全选或取消全选当前可见项，保留隐藏项原有选择；超限时整体拒绝不静默截断。 */
  toggleVisible(visibleBundles: string[]): string {
    if (this.mode === 'off' || visibleBundles.length === 0) {
      return '';
    }
    const current = this.activeList();
    const selected = new Set<string>(current);
    const allVisibleSelected = visibleBundles.every((item: string): boolean => selected.has(item));
    if (allVisibleSelected) {
      const visible = new Set<string>(visibleBundles);
      this.setActiveList(current.filter((item: string): boolean => !visible.has(item)));
      return '';
    }
    const next = current.slice();
    for (const item of visibleBundles) {
      if (!selected.has(item)) {
        selected.add(item);
        next.push(item);
      }
    }
    if (next.length > this.activeLimit()) {
      return 'too_many_apps';
    }
    this.setActiveList(next);
    return '';
  }

  clearActive(): void {
    this.setActiveList([]);
  }

  private pin(bundles: string[]): void {
    for (const bundle of bundles) {
      if (!this.pinnedOnOpen.includes(bundle)) {
        this.pinnedOnOpen.push(bundle);
      }
    }
  }

  applyImport(raw: string, ownBundle: string, replace: boolean): AccessControlImportOutcome {
    const current = this.activeList();
    const parsed = parseBundleImportText(raw, ownBundle);
    if (parsed.valid.length === 0) {
      return {
        ok: false,
        error: parsed.skippedOwn && parsed.invalid.length === 0 ? 'own_bundle_only' : 'invalid_bundle_name',
        addedCount: 0,
        totalCount: current.length,
        invalidCount: parsed.invalid.length,
        skippedOwn: parsed.skippedOwn
      };
    }
    const merged = replace ? new Set<string>() : new Set<string>(current);
    let added = 0;
    for (const bundle of parsed.valid) {
      if (!merged.has(bundle)) {
        merged.add(bundle);
        ++added;
      }
    }
    const next = Array.from(merged);
    if (next.length > this.activeLimit()) {
      return {
        ok: false,
        error: 'too_many_apps',
        addedCount: 0,
        totalCount: current.length,
        invalidCount: parsed.invalid.length,
        skippedOwn: parsed.skippedOwn
      };
    }
    this.setActiveList(next);
    this.pin(parsed.valid);
    return {
      ok: true,
      error: '',
      addedCount: replace ? next.length : added,
      totalCount: next.length,
      invalidCount: parsed.invalid.length,
      skippedOwn: parsed.skippedOwn
    };
  }

  /** 选择器结果并入当前名单：沿用导入的去重、跳过自身和上限校验，成功后才记下应用名。 */
  applyPicked(apps: AccessPickedApp[], ownBundle: string): AccessControlImportOutcome {
    const text = apps.map((app: AccessPickedApp): string => app.bundleName).join('\n');
    const outcome = this.applyImport(text, ownBundle, false);
    if (outcome.ok) {
      for (const app of apps) {
        const label = app.label.trim();
        if (label !== '' && app.bundleName !== ownBundle) {
          this.labels.set(app.bundleName, label);
        }
      }
    }
    return outcome;
  }

  /** 两份名单的并集，用于保存时裁剪应用名。 */
  allBundles(): string[] {
    return Array.from(new Set<string>(this.excluded.concat(this.trusted)));
  }

  exportText(): string {
    return this.activeList().join('\n');
  }

  isDirty(): boolean {
    return this.mode !== this.baseline.appAccessMode ||
      !sameBundleSet(this.excluded, this.baseline.excludedApplications) ||
      !sameBundleSet(this.trusted, this.baseline.trustedApplications);
  }

  /** 只列出会生效的变化：开关或模式变化，以及开启时当前模式名单的增删。 */
  changes(): AccessControlChanges {
    const lists: AccessListChange[] = [];
    if (this.mode !== 'off') {
      const change = this.activeMode === 'trusted' ?
        listChange('trusted', this.baseline.trustedApplications, this.trusted) :
        listChange('blocked', this.baseline.excludedApplications, this.excluded);
      if (change.added > 0 || change.removed > 0) {
        lists.push(change);
      }
    }
    return { fromMode: this.baseline.appAccessMode, toMode: this.mode, lists: lists };
  }

  toSettings(): VpnNetworkSettings {
    const next = this.baseline.copy();
    next.appAccessMode = this.mode;
    next.excludedApplications = this.excluded.slice();
    next.trustedApplications = this.trusted.slice();
    return next;
  }

  effectiveChanged(): boolean {
    return !vpnAccessEffectiveEqual(this.baseline, this.toSettings());
  }

  validationError(): string {
    if (this.mode === 'trusted' && this.trusted.length === 0) {
      return 'empty_trusted_apps';
    }
    if (this.excluded.length > MAX_VPN_EXCLUDED_APPS || this.trusted.length > MAX_VPN_TRUSTED_APPS) {
      return 'too_many_apps';
    }
    return '';
  }

  private appEntry(bundleName: string, entry: AccessCatalogEntry | undefined, chinese: boolean): AccessListEntry {
    if (entry !== undefined) {
      const title = chinese ? entry.nameZh : entry.nameEn;
      return new AccessListEntry('app', bundleName, title, entry.containerNote === true, entry.iconColor,
        brandInk(entry.iconColor), title.slice(0, 1).toUpperCase(), 'common', 0, false, false);
    }
    const label = this.labels.get(bundleName) ?? '';
    if (label === '') {
      return new AccessListEntry('app', bundleName, '', false, '', '', '#', 'common', 0, false, false);
    }
    const tone = generatedTone(bundleName);
    return new AccessListEntry('app', bundleName, label, false, tone[0], tone[1], label.slice(0, 1).toUpperCase(),
      'common', 0, false, false);
  }

  /**
   * 列表的全部行：「添加应用」与已选应用同一张卡，「常用应用」另一张卡；有搜索词时首行换成结果数，
   * 没有任何结果时只给一个 empty 行。iconColor 为空串表示用中性底色显示「#」。
   */
  entries(query: string, category: AccessAppCategory, chinese: boolean,
    catalog: AccessCatalogEntry[] = ACCESS_CONTROL_CATALOG): AccessListEntry[] {
    if (this.mode === 'off') {
      return [];
    }
    const words = query.trim().toLowerCase().split(/\s+/).filter((word: string): boolean => word !== '');
    const searching = words.length > 0;
    const selected = new Set<string>(this.activeList());
    const catalogByBundle = new Map<string, AccessCatalogEntry>();
    for (const entry of catalog) {
      catalogByBundle.set(entry.bundleName, entry);
    }
    const inCategory = (bundleName: string): boolean => {
      if (category === 'all') {
        return true;
      }
      if (category === 'selected') {
        return selected.has(bundleName);
      }
      return catalogByBundle.get(bundleName)?.category === category;
    };

    // 已选分组 = 打开时的快照 + 本次新加的，取消勾选的仍留在原位，便于误触后重新勾选。
    const pinned = new Set<string>(this.pinnedOnOpen);
    for (const bundle of this.activeList()) {
      pinned.add(bundle);
    }
    const top: AccessListEntry[] = [];
    for (const bundle of Array.from(pinned)) {
      const entry = catalogByBundle.get(bundle);
      if (inCategory(bundle) && entryMatchesQuery(bundle, entry, words, this.labels.get(bundle) ?? '')) {
        top.push(this.appEntry(bundle, entry, chinese));
      }
    }
    const rest: AccessListEntry[] = [];
    if (category !== 'selected') {
      for (const entry of catalog) {
        if (!pinned.has(entry.bundleName) && inCategory(entry.bundleName) &&
          entryMatchesQuery(entry.bundleName, entry, words)) {
          rest.push(this.appEntry(entry.bundleName, entry, chinese));
        }
      }
    }

    const total = top.length + rest.length;
    if (searching && total === 0) {
      return [new AccessListEntry('empty', '', '', false, '', '', '', 'results', 0, true, true)];
    }
    const result: AccessListEntry[] = [];
    if (searching) {
      result.push(new AccessListEntry('label', '', '', false, '', '', '', 'results', total, false, false));
    }
    const firstCard: AccessListEntry[] = searching ? top :
      [new AccessListEntry('add', '', '', false, '', '', '', 'common', 0, false, false)].concat(top);
    firstCard.forEach((item: AccessListEntry, index: number): void => {
      result.push(item.withEdges(index === 0, index === firstCard.length - 1));
    });
    if (rest.length > 0) {
      result.push(new AccessListEntry('label', '', '', false, '', '', '', 'common', 0, false, false));
      rest.forEach((item: AccessListEntry, index: number): void => {
        result.push(item.withEdges(index === 0, index === rest.length - 1));
      });
    }
    return result;
  }
}

/** entries() 里可勾选的应用包名，供「全选可见」使用。 */
export function accessVisibleBundles(entries: AccessListEntry[]): string[] {
  return entries.filter((item: AccessListEntry): boolean => item.kind === 'app')
    .map((item: AccessListEntry): string => item.bundleName);
}
