import { connection } from '../../client/Connection';
import { ProfileEvent, ProfileEvents } from '../../client/ProfileCommands';
import { ProxySnapshot, readOfflineProxies, readOnlineProxies } from '../../client/Proxies';
import { ListSource } from '../../components/ListSource';
import {
  proxyColumnCount, proxyGroupNames,
  ProxyStyle, ProxyViewState, validProxyView
} from './ProxyLogic';
import { ProxyAppearance } from './ProxyAppearance';
import { ProxyViewPatch } from './ProxyPreferences';
import { ProxySelectionSession } from './ProxySelection';
import { ProxyTestSession } from './ProxyTests';
import { applyProxyDelayViews, buildProxyViews, ProxyBrowserInput, ProxyGroupView, ProxyLocateTarget, ProxyNodeView } from './ProxyView';


@ObservedV2
export class ProxyBrowser {
  @Trace groups: ProxyGroupView[] = [];
  @Trace query: string = '';
  @Trace currentGroup: string = '';
  @Trace loading: boolean = false;
  @Trace loadError: boolean = false;
  @Trace stale: boolean = false;
  @Trace notice: string = '';
  @Trace online: boolean = false;
  @Trace offlineWritable: boolean = false;
  @Trace totalGroups: number = 0;
  @Trace groupIndex: number = 0;
  readonly source: ListSource<ProxyGroupView> = new ListSource<ProxyGroupView>();
  readonly listOffsets: Map<string, number> = new Map<string, number>();
  readonly tabOffsets: Map<string, number> = new Map<string, number>();
  @Trace appearance: ProxyAppearance = new ProxyAppearance((): void => this.rebuild());
  private input?: ProxyBrowserInput;
  private snapshot?: ProxySnapshot;
  private view: ProxyViewState = { expanded: [], currentGroup: '' };
  private preferencesLoaded: boolean = false;
  private availableWidth: number = 360;
  private refreshSequence: number = 0;
  private contextEpoch: number = 0;
  private snapshotEpoch: number = -1;
  private mutation: number = 0;
  private selection: ProxySelectionSession = new ProxySelectionSession((): void => {
    this.mutation++;
    this.rebuild();
  }, (notice: string): void => { this.notice = notice; }, (): void => { this.refresh(); });
  private tests: ProxyTestSession = new ProxyTestSession((rebuild: boolean): void => {
    if (rebuild) {
      this.rebuild();
    } else {
      applyProxyDelayViews(this.groups, this.tests.latest, this.tests.phases, this.tests.testingGroups);
    }
  }, (notice: string): void => { this.notice = notice; });
  private events: ProfileEvents = new ProfileEvents((event: ProfileEvent): void => {
    if ((event.type === 'updated' && event.ok === true) ||
      (event.type === 'reloaded' && event.profile === this.input?.profile)) {
      this.refresh();
    }
  });

  get style(): ProxyStyle {
    return this.appearance.style;
  }

  get preferenceError(): boolean {
    return this.appearance.error;
  }

  configure(input: ProxyBrowserInput): void {
    const previous = this.input;
    const changedProfile = previous?.profile !== input.profile;
    const changedContext = changedProfile || previous?.online !== input.online ||
      previous?.offlineWritable !== input.offlineWritable || previous?.mode !== input.mode ||
      previous?.bootId !== input.bootId || previous?.summary?.revision !== input.summary?.revision;
    const refresh = changedContext || previous?.summary !== input.summary || previous?.ready !== input.ready ||
      previous?.visible !== input.visible;
    this.input = input;
    if (input.visible && previous?.visible !== true) {
      this.preferencesLoaded = false;
    }
    this.online = input.online;
    this.offlineWritable = input.offlineWritable;
    if (changedContext) {
      this.contextEpoch++;
      this.refreshSequence++;
      this.tests.cancel(true);
      this.selection.clear();
    }
    if (changedProfile) {
      this.snapshot = undefined;
      this.groups = [];
      this.source.replace([]);
      this.totalGroups = 0;
      this.currentGroup = '';
      this.view = { expanded: [], currentGroup: '' };
      this.preferencesLoaded = false;
      this.notice = '';
      this.loadError = false;
      this.stale = false;
    }
    this.selection.unobserve();
    this.events.stop();
    if (!input.visible) {
      this.refreshSequence++;
      this.loading = false;
      this.tests.cancel();
      return;
    }
    this.selection.observe((): ProxySnapshot | undefined =>
      this.snapshotEpoch === this.contextEpoch ? this.snapshot : undefined);
    if (input.online) {
      this.events.start(input.context.filesDir);
    }
    if (refresh) {
      this.refresh();
    }
  }

  suspend(): void {
    this.refreshSequence++;
    this.selection.unobserve();
    this.events.stop();
    this.tests.cancel();
    this.loading = false;
    if (this.input !== undefined) {
      this.input.visible = false;
    }
  }

  async refresh(): Promise<void> {
    const input = this.input;
    if (input === undefined || !input.visible || input.profile === '') {
      return;
    }
    const sequence = ++this.refreshSequence;
    const mutation = this.mutation;
    this.loading = this.snapshot === undefined;
    try {
      if (!this.preferencesLoaded) {
        try {
          const view = await this.appearance.load(input.context, input.profile,
            (): boolean => sequence === this.refreshSequence);
          if (sequence !== this.refreshSequence) {
            return;
          }
          this.view = view;
        } catch (e) {
          if (sequence === this.refreshSequence) {
            this.appearance.error = true;
          }
        }
        if (sequence !== this.refreshSequence) {
          return;
        }
        this.preferencesLoaded = true;
      }
      let snapshot: ProxySnapshot;
      if (input.online) {
        snapshot = await readOnlineProxies(input.context.filesDir, input.profile, input.summary);
      } else if (!input.offlineWritable && this.snapshot !== undefined && this.snapshot.profile === input.profile) {
        const cached = this.snapshot;
        snapshot = {
          profile: cached.profile, bootId: cached.bootId, revision: cached.revision, configRevision: cached.configRevision,
          online: false, offlineWritable: false, mode: input.mode, nodes: cached.nodes, memberNodes: cached.memberNodes,
          actualNodes: cached.actualNodes, groups: cached.groups, selected: cached.selected
        };
      } else if (input.summary !== undefined) {
        snapshot = await readOfflineProxies(input.context.filesDir, input.profile, input.summary, input.mode,
          input.offlineWritable);
      } else {
        if (!input.ready) {
          return;
        }
        throw new Error('proxy_summary_unavailable');
      }
      if (sequence !== this.refreshSequence || input.profile !== this.input?.profile || mutation !== this.mutation) {
        return;
      }
      if (this.snapshot?.revision !== snapshot.revision || this.snapshot?.online !== snapshot.online ||
        this.snapshot?.offlineWritable !== snapshot.offlineWritable) {
        this.tests.cancel(true);
        this.contextEpoch++;
      }
      const names = proxyGroupNames(snapshot);
      if (this.snapshot === undefined && names.includes(input.initialGroup)) {
        this.view.currentGroup = input.initialGroup;
      }
      this.snapshot = snapshot;
      this.snapshotEpoch = this.contextEpoch;
      this.view = validProxyView(this.view, names, snapshot.mode);
      this.tests.seed(snapshot);
      this.loadError = false;
      this.stale = false;
      this.rebuild();
    } catch (e) {
      if (sequence === this.refreshSequence) {
        this.loadError = true;
        this.stale = this.snapshot !== undefined;
      }
    } finally {
      if (sequence === this.refreshSequence) {
        this.loading = false;
      }
    }
  }

  setQuery(query: string): void {
    this.query = query;
    this.rebuild();
  }

  resize(availableWidth: number): void {
    if (availableWidth > 0 && proxyColumnCount(this.availableWidth, this.style.layout) !==
      proxyColumnCount(availableWidth, this.style.layout)) {
      this.availableWidth = availableWidth;
      this.rebuild();
    } else if (availableWidth > 0) {
      this.availableWidth = availableWidth;
    }
  }

  toggleGroup(name: string): void {
    const expanded = this.view.expanded.includes(name) ?
      this.view.expanded.filter((candidate: string): boolean => candidate !== name) : [...this.view.expanded, name];
    this.view = { expanded: expanded, currentGroup: this.view.currentGroup };
    this.persistView(expanded, undefined);
    this.rebuild();
  }

  setCurrentGroup(name: string): void {
    if (this.view.currentGroup === name || this.snapshot === undefined || !proxyGroupNames(this.snapshot).includes(name)) {
      return;
    }
    this.view = { expanded: this.view.expanded, currentGroup: name };
    this.persistView(undefined, name);
    this.rebuild();
  }

  choose(group: string, node: string): void {
    this.select(group, node, false);
  }

  clearPin(group: string): void {
    this.select(group, '', true);
  }

  private select(group: string, node: string, clearPin: boolean): void {
    const snapshot = this.snapshot;
    const input = this.input;
    if (snapshot === undefined || input === undefined || !input.visible || connection.busy || this.loadError ||
      snapshot.online !== input.online || snapshot.offlineWritable !== input.offlineWritable ||
      (!input.online && !input.offlineWritable) || this.snapshotEpoch !== this.contextEpoch) {
      this.notice = 'notReady';
      return;
    }
    this.notice = '';
    const epoch = this.contextEpoch;
    const stillCurrent = (): boolean => epoch === this.contextEpoch && this.input?.profile === snapshot.profile &&
      this.input?.online === snapshot.online && this.input?.offlineWritable === snapshot.offlineWritable &&
      (snapshot.online ? connection.hostState === 'running' : connection.offlineWritable);
    if (clearPin) {
      this.selection.clearPin(input.context.filesDir, snapshot, group, this.appearance.closeConnections, stillCurrent);
    } else {
      this.selection.choose(input.context.filesDir, snapshot, group, node, this.appearance.closeConnections, stillCurrent);
    }
  }

  test(group: string, node: string = ''): void {
    if (this.input?.visible === true && this.snapshot?.online === true && connection.hostState === 'running' &&
      !connection.busy && !this.loadError && this.snapshotEpoch === this.contextEpoch) {
      this.notice = '';
      this.tests.start(this.input.context.filesDir, this.snapshot, group, this.query, node);
    } else {
      this.notice = this.online ? 'notReady' : 'offline';
    }
  }

  locate(groupName: string): ProxyLocateTarget | undefined {
    const groupIndex = this.groups.findIndex((group: ProxyGroupView): boolean => group.name === groupName);
    const group = this.groups[groupIndex];
    const index = group?.nodes.findIndex((card: ProxyNodeView): boolean => card.pinned || card.selected) ?? -1;
    if (group === undefined || index < 0) {
      this.notice = 'filtered';
      return undefined;
    }
    if (!group.expanded) {
      this.toggleGroup(groupName);
    }
    return { groupIndex: groupIndex, rowIndex: Math.floor(index / proxyColumnCount(this.availableWidth, this.style.layout)) };
  }

  changeStyle(style: ProxyStyle): void {
    if (this.input !== undefined) {
      this.appearance.change(this.input.context, style);
    }
  }

  async retryPreferences(): Promise<void> {
    const input = this.input;
    if (input === undefined) {
      return;
    }
    const epoch = this.contextEpoch;
    const stillCurrent = (): boolean => this.input?.profile === input.profile && epoch === this.contextEpoch;
    try {
      const retry = this.appearance.retry(input.context, input.profile, stillCurrent);
      const version = this.appearance.viewIntentVersion;
      const view = await retry;
      if (stillCurrent() && version === this.appearance.viewIntentVersion && view !== undefined) {
        this.view = view;
        this.rebuild();
      }
    } catch (e) {
      if (stillCurrent()) {
        this.appearance.error = true;
      }
    }
  }

  private persistView(expanded: string[] | undefined, current: string | undefined): void {
    const input = this.input;
    if (input === undefined) {
      return;
    }
    const patch: ProxyViewPatch = { expanded: expanded, currentGroup: current };
    this.appearance.persistView(input.context, input.profile, patch,
      (): boolean => this.input?.profile === input.profile);
  }

  private rebuild(): void {
    const snapshot = this.snapshot;
    if (snapshot === undefined) {
      return;
    }
    this.totalGroups = proxyGroupNames(snapshot).length;
    this.groups = buildProxyViews({
      snapshot: snapshot, style: this.style, view: this.view, query: this.query,
      columns: proxyColumnCount(this.availableWidth, this.style.layout), latest: this.tests.latest,
      completedForGroup: (name: string): Map<string, number> => this.tests.completedFor(name),
      phases: this.tests.phases, pending: this.selection.pending,
      testingGroups: this.tests.testingGroups, previous: this.groups, picker: this.input?.picker ?? false
    });
    this.currentGroup = this.groups.some((group: ProxyGroupView): boolean => group.name === this.view.currentGroup) ?
      this.view.currentGroup : this.groups[0]?.name ?? '';
    this.groupIndex = Math.max(0, this.groups.findIndex((group: ProxyGroupView): boolean => group.name === this.currentGroup));
    this.source.replace(this.groups);
  }
}
