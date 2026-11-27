import {
  MAX_VPN_EXCLUDED_APPS, MAX_VPN_TRUSTED_APPS, parseBundleImportText, vpnAccessEffectiveEqual, VpnAppAccessMode,
  VpnNetworkSettings
} from '../../shared/VpnNetwork';
import { ACCESS_CONTROL_CATALOG, AccessAppCategory, AccessCatalogEntry } from './AccessControlCatalog';

export class AccessControlRowItem {
  readonly key: string;
  readonly bundleName: string;
  readonly title: string;
  readonly category: AccessAppCategory;
  readonly custom: boolean;
  readonly containerNote: boolean;

  constructor(bundleName: string, title: string, category: AccessAppCategory, custom: boolean, containerNote: boolean) {
    this.key = bundleName;
    this.bundleName = bundleName;
    this.title = title;
    this.category = category;
    this.custom = custom;
    this.containerNote = containerNote;
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

/** 离开确认页展示的修改摘要：模式变化和有增删的名单，当前模式的名单排在前面。 */
export interface AccessControlChanges {
  fromMode: VpnAppAccessMode;
  toMode: VpnAppAccessMode;
  lists: AccessListChange[];
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

function entryMatchesQuery(bundleName: string, entry: AccessCatalogEntry | undefined, words: string[]): boolean {
  if (words.length === 0) {
    return true;
  }
  const haystack = entry === undefined ? bundleName.toLowerCase() :
    `${entry.nameZh} ${entry.nameEn} ${entry.bundleName} ${entry.keywords.join(' ')}`.toLowerCase();
  return words.every((word: string): boolean => haystack.includes(word));
}

/** 应用访问控制草稿状态：独立维护黑/白双名单，打开或切换模式时快照置顶项，勾选不跳行。 */
export class AccessControlDraft {
  private readonly baseline: VpnNetworkSettings;
  mode: VpnAppAccessMode;
  excluded: string[];
  trusted: string[];
  private pinnedOnOpen: Set<string>;

  constructor(initial: VpnNetworkSettings) {
    this.baseline = initial.copy();
    this.mode = initial.appAccessMode;
    this.excluded = initial.excludedApplications.slice();
    this.trusted = initial.trustedApplications.slice();
    this.pinnedOnOpen = new Set<string>(this.activeList());
  }

  activeList(): string[] {
    if (this.mode === 'trusted') {
      return this.trusted;
    }
    if (this.mode === 'blocked') {
      return this.excluded;
    }
    return [];
  }

  activeLimit(): number {
    if (this.mode === 'trusted') {
      return MAX_VPN_TRUSTED_APPS;
    }
    if (this.mode === 'blocked') {
      return MAX_VPN_EXCLUDED_APPS;
    }
    return 0;
  }

  private setActiveList(next: string[]): void {
    if (this.mode === 'trusted') {
      this.trusted = next;
    } else if (this.mode === 'blocked') {
      this.excluded = next;
    }
  }

  setMode(next: VpnAppAccessMode): void {
    if (this.mode === next) {
      return;
    }
    this.mode = next;
    this.pinnedOnOpen = new Set<string>(this.activeList());
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
    if (this.mode !== 'off') {
      this.setActiveList([]);
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
    for (const bundle of parsed.valid) {
      this.pinnedOnOpen.add(bundle);
    }
    return {
      ok: true,
      error: '',
      addedCount: replace ? next.length : added,
      totalCount: next.length,
      invalidCount: parsed.invalid.length,
      skippedOwn: parsed.skippedOwn
    };
  }

  exportText(): string {
    return this.activeList().join('\n');
  }

  isDirty(): boolean {
    return this.mode !== this.baseline.appAccessMode ||
      !sameBundleSet(this.excluded, this.baseline.excludedApplications) ||
      !sameBundleSet(this.trusted, this.baseline.trustedApplications);
  }

  changes(): AccessControlChanges {
    const blocked = listChange('blocked', this.baseline.excludedApplications, this.excluded);
    const trusted = listChange('trusted', this.baseline.trustedApplications, this.trusted);
    const ordered = this.mode === 'trusted' ? [trusted, blocked] : [blocked, trusted];
    return {
      fromMode: this.baseline.appAccessMode,
      toMode: this.mode,
      lists: ordered.filter((item: AccessListChange): boolean => item.added > 0 || item.removed > 0)
    };
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

  rows(query: string, category: AccessAppCategory, chinese: boolean,
    catalog: AccessCatalogEntry[] = ACCESS_CONTROL_CATALOG): AccessControlRowItem[] {
    if (this.mode === 'off') {
      return [];
    }
    const words = query.trim().toLowerCase().split(/\s+/).filter((word: string): boolean => word !== '');
    const catalogByBundle = new Map<string, AccessCatalogEntry>();
    for (const entry of catalog) {
      catalogByBundle.set(entry.bundleName, entry);
    }
    // 自定义包名在本次编辑取消勾选后仍保留在可见列表中，便于误触后重新勾选。
    const customBundles = new Set<string>();
    for (const bundle of this.activeList()) {
      if (!catalogByBundle.has(bundle)) {
        customBundles.add(bundle);
      }
    }
    for (const bundle of Array.from(this.pinnedOnOpen)) {
      if (!catalogByBundle.has(bundle)) {
        customBundles.add(bundle);
      }
    }

    const pinnedCustom: AccessControlRowItem[] = [];
    const pinnedCatalog: AccessControlRowItem[] = [];
    const restCustom: AccessControlRowItem[] = [];
    const restCatalog: AccessControlRowItem[] = [];

    if (category === 'all') {
      for (const bundle of Array.from(customBundles)) {
        if (!entryMatchesQuery(bundle, undefined, words)) {
          continue;
        }
        const row = new AccessControlRowItem(bundle, '', 'all', true, false);
        if (this.pinnedOnOpen.has(bundle)) {
          pinnedCustom.push(row);
        } else {
          restCustom.push(row);
        }
      }
    }

    for (const entry of catalog) {
      if (category !== 'all' && entry.category !== category) {
        continue;
      }
      if (!entryMatchesQuery(entry.bundleName, entry, words)) {
        continue;
      }
      const row = new AccessControlRowItem(
        entry.bundleName,
        chinese ? entry.nameZh : entry.nameEn,
        entry.category,
        false,
        entry.containerNote === true
      );
      if (this.pinnedOnOpen.has(entry.bundleName)) {
        pinnedCatalog.push(row);
      } else {
        restCatalog.push(row);
      }
    }

    return pinnedCustom.concat(pinnedCatalog, restCustom, restCatalog);
  }
}
