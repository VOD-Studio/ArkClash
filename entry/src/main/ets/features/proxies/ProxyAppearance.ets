import { common } from '@kit.AbilityKit';
import { copyProxyStyle, defaultProxyStyle, ProxyStyle, ProxyViewState } from './ProxyLogic';
import { loadProxyPreferences, ProxyViewPatch, saveProxyStyle, saveProxyView } from './ProxyPreferences';

interface ProxyViewDraft extends ProxyViewPatch {
  expandedVersion: number;
  currentGroupVersion: number;
  expandedFailed: boolean;
  currentGroupFailed: boolean;
}

function copyViewPatch(patch: ProxyViewPatch): ProxyViewPatch {
  return { expanded: patch.expanded?.slice(), currentGroup: patch.currentGroup };
}

@ObservedV2
export class ProxyAppearance {
  @Trace style: ProxyStyle = defaultProxyStyle();
  @Trace error: boolean = false;
  closeConnections: boolean = true;
  private revision: number = 0;
  private saved: ProxyStyle = defaultProxyStyle();
  private draft?: ProxyStyle;
  private currentProfile: string = '';
  private viewDrafts: Map<string, ProxyViewDraft> = new Map<string, ProxyViewDraft>();
  private viewRevisions: Map<string, number> = new Map<string, number>();
  private sequence: number = 0;
  private viewSequence: number = 0;
  private writes: Promise<void> = Promise.resolve();
  private viewWrites: Promise<void> = Promise.resolve();
  private onChange: () => void;

  constructor(onChange: () => void) {
    this.onChange = onChange;
  }

  get viewIntentVersion(): number {
    return this.viewSequence;
  }

  async load(context: common.UIAbilityContext, profile: string, stillCurrent: () => boolean): Promise<ProxyViewState> {
    const saved = await loadProxyPreferences(context, profile);
    if (!stillCurrent()) {
      throw new Error('proxy_preferences_stale');
    }
    this.currentProfile = profile;
    this.style = saved.style;
    this.saved = copyProxyStyle(saved.style);
    this.revision = saved.styleRevision;
    this.viewRevisions.set(profile, saved.viewRevision);
    this.closeConnections = saved.closeConnections;
    this.updateError(profile);
    return saved.view;
  }

  change(context: common.UIAbilityContext, style: ProxyStyle): void {
    const sequence = ++this.sequence;
    this.style = copyProxyStyle(style);
    this.onChange();
    this.writes = this.writes.then(async (): Promise<void> => {
      this.revision = await saveProxyStyle(context, this.revision, style);
      this.saved = copyProxyStyle(style);
      if (sequence === this.sequence) {
        this.draft = undefined;
        this.style = copyProxyStyle(style);
        this.updateError(this.currentProfile);
        this.onChange();
      }
    }).catch((): void => {
      if (sequence === this.sequence) {
        this.draft = copyProxyStyle(style);
        this.style = copyProxyStyle(this.saved);
        this.error = true;
        this.onChange();
      }
    });
  }

  persistView(context: common.UIAbilityContext, profile: string, change: ProxyViewPatch,
    stillCurrent: () => boolean): Promise<void> {
    const version = ++this.viewSequence;
    const patch = copyViewPatch(change);
    this.rememberViewDraft(profile, patch, version);
    const write = this.viewWrites.then(async (): Promise<void> => {
      const result = await saveProxyView(context, profile, this.viewRevisions.get(profile) ?? 0, patch);
      this.viewRevisions.set(profile, result.revision);
      this.finishViewDraft(profile, patch, version, version);
      if (stillCurrent()) {
        this.updateError(profile);
      }
    }).catch((): void => {
      this.failViewDraft(profile, patch, version, version);
      if (stillCurrent()) {
        this.updateError(profile);
      }
    });
    this.viewWrites = write;
    return write;
  }

  async retry(context: common.UIAbilityContext, profile: string,
    stillCurrent: () => boolean): Promise<ProxyViewState | undefined> {
    const version = ++this.viewSequence;
    const styleVersion = this.sequence;
    await this.viewWrites;
    if (!stillCurrent() || version !== this.viewSequence) {
      return undefined;
    }
    const saved = await loadProxyPreferences(context, profile);
    if (!stillCurrent() || version !== this.viewSequence) {
      return undefined;
    }
    this.currentProfile = profile;
    this.viewRevisions.set(profile, saved.viewRevision);
    if (styleVersion === this.sequence) {
      this.revision = saved.styleRevision;
      this.saved = copyProxyStyle(saved.style);
      if (this.draft !== undefined) {
        this.change(context, this.draft);
      } else {
        this.style = saved.style;
      }
    }
    const draft = this.viewDrafts.get(profile);
    if (draft === undefined) {
      this.updateError(profile);
      return saved.view;
    }
    const patch = copyViewPatch(draft);
    const expandedVersion = draft.expandedVersion;
    const currentGroupVersion = draft.currentGroupVersion;
    const write = this.viewWrites.then(async (): Promise<ProxyViewState | undefined> => {
      if (!stillCurrent() || version !== this.viewSequence) {
        return undefined;
      }
      const result = await saveProxyView(context, profile, saved.viewRevision, patch);
      this.viewRevisions.set(profile, result.revision);
      this.finishViewDraft(profile, patch, expandedVersion, currentGroupVersion);
      return result.view;
    });
    this.viewWrites = write.then((): void => {}, (): void => {});
    try {
      const view = await write;
      if (!stillCurrent() || version !== this.viewSequence) {
        return undefined;
      }
      this.updateError(profile);
      return view;
    } catch (e) {
      this.failViewDraft(profile, patch, expandedVersion, currentGroupVersion);
      if (stillCurrent()) {
        this.updateError(profile);
      }
      throw e as Error;
    }
  }

  private rememberViewDraft(profile: string, patch: ProxyViewPatch, version: number): void {
    const draft: ProxyViewDraft = this.viewDrafts.get(profile) ?? {
      expandedVersion: 0, currentGroupVersion: 0, expandedFailed: false, currentGroupFailed: false
    };
    if (patch.expanded !== undefined) {
      draft.expanded = patch.expanded;
      draft.expandedVersion = version;
      draft.expandedFailed = false;
    }
    if (patch.currentGroup !== undefined) {
      draft.currentGroup = patch.currentGroup;
      draft.currentGroupVersion = version;
      draft.currentGroupFailed = false;
    }
    this.viewDrafts.set(profile, draft);
  }

  private finishViewDraft(profile: string, patch: ProxyViewPatch,
    expandedVersion: number, currentGroupVersion: number): void {
    const draft = this.viewDrafts.get(profile);
    if (draft === undefined) {
      return;
    }
    // 旧提交只清除自己提交的字段版本，不清除期间产生的新草稿。
    if (patch.expanded !== undefined && draft.expandedVersion === expandedVersion) {
      draft.expanded = undefined;
      draft.expandedVersion = 0;
      draft.expandedFailed = false;
    }
    if (patch.currentGroup !== undefined && draft.currentGroupVersion === currentGroupVersion) {
      draft.currentGroup = undefined;
      draft.currentGroupVersion = 0;
      draft.currentGroupFailed = false;
    }
    if (draft.expanded === undefined && draft.currentGroup === undefined) {
      this.viewDrafts.delete(profile);
    }
  }

  private failViewDraft(profile: string, patch: ProxyViewPatch,
    expandedVersion: number, currentGroupVersion: number): void {
    const draft = this.viewDrafts.get(profile);
    if (draft === undefined) {
      return;
    }
    if (patch.expanded !== undefined && draft.expandedVersion === expandedVersion) {
      draft.expandedFailed = true;
    }
    if (patch.currentGroup !== undefined && draft.currentGroupVersion === currentGroupVersion) {
      draft.currentGroupFailed = true;
    }
  }

  private updateError(profile: string): void {
    const draft = this.viewDrafts.get(profile);
    this.error = this.draft !== undefined || draft?.expandedFailed === true || draft?.currentGroupFailed === true;
  }
}
