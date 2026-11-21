import { common } from '@kit.AbilityKit';
import { OutboundMode } from '../../client/Controller';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { ProxyDelayPhase, ProxyNodeSnapshot, ProxySnapshot, isProxyGroup, proxyMemberNode } from '../../client/Proxies';
import { KeyedListSource } from '../../components/KeyedListSource';
import {
  canTestProxy, ProxyDensity, ProxyIconStyle, ProxyStyle, ProxyViewState,
  proxyDelayKey, proxyGroupNames, proxyMembers, proxyPinnedMemberId, resolveProxyLeaf, selectableProxyGroup
} from './ProxyLogic';

export interface ProxyBrowserInput {
  context: common.UIAbilityContext;
  profile: string;
  summary: ProfileSummary | undefined;
  ready: boolean;
  visible: boolean;
  online: boolean;
  offlineWritable: boolean;
  bootId: string;
  configRevision: number;
  mode: OutboundMode;
  picker: boolean;
  initialGroup: string;
}

export interface ProxyPendingSelection {
  operationId: string;
  target: string;
  clearPin: boolean;
}
export interface ProxyLocateTarget {
  groupIndex: number;
  rowIndex: number;
}


@ObservedV2
export class ProxyNodeView {
  key: string;
  id: string;
  name: string;
  @Trace type: string = '';
  @Trace online: boolean = false;
  @Trace addressable: boolean = true;
  @Trace selectable: boolean = false;
  @Trace leafName: string = '';
  @Trace leafRetired: boolean = false;
  @Trace nested: boolean = false;
  @Trace unresolved: boolean = false;
  @Trace selected: boolean = false;
  @Trace pinned: boolean = false;
  @Trace pending: boolean = false;
  @Trace located: boolean = false;
  @Trace testable: boolean = false;
  @Trace delay: number = 0;
  @Trace phase: ProxyDelayPhase = 'idle';
  delayKey: string = '';

  constructor(key: string, id: string, name: string) {
    this.key = key;
    this.id = id;
    this.name = name;
  }
}

@ObservedV2
export class ProxyNodeRow {
  key: string;
  nodes: ProxyNodeView[];
  blanks: string[];
  @Trace last: boolean = false;

  constructor(key: string, nodes: ProxyNodeView[], columns: number) {
    this.key = key;
    this.nodes = nodes;
    this.blanks = [];
    for (let index = nodes.length; index < columns; index++) {
      this.blanks.push(`blank.${index}`);
    }
  }
}

@ObservedV2
export class ProxyGroupReveal {
  @Trace running: boolean = false;
  @Trace extent: number = 0;
  @Trace rows: ProxyNodeRow[] = [];
  firstRow: number = 0;
  crop: number = 0;
  fullExtent: number = 0;
  rowExtent: number = 0;
  anchorOffset: number = 0;
  version: number = 0;

  begin(rows: ProxyNodeRow[], rowExtent: number, viewportHeight: number, expanded: boolean): void {
    this.firstRow = Math.max(0, Math.min(rows.length - 1, this.firstRow));
    this.crop = Math.max(0, Math.min(rowExtent, this.crop));
    this.rowExtent = rowExtent;
    const count = Math.max(1, Math.ceil(Math.max(0, viewportHeight) / rowExtent) + 1);
    this.rows = rows.slice(this.firstRow, this.firstRow + count);
    this.fullExtent = Math.max(0, this.rows.length * rowExtent - this.crop +
      (this.rows.length > 0 && this.firstRow + this.rows.length === rows.length ? 2 : 0));
    this.extent = expanded ? this.fullExtent : 0;
    this.running = this.rows.length > 0;
  }
}

@ObservedV2
export class ProxyGroupView {
  key: string;
  name: string;
  readonly profile: string;
  @Trace type: string = '';
  @Trace now: string = '';
  @Trace actualRetired: boolean = false;
  @Trace pinned: string = '';
  @Trace expanded: boolean = false;
  @Trace dynamic: boolean = false;
  @Trace testing: boolean = false;
  @Trace icon: string = '';
  @Trace iconStyle: ProxyIconStyle = 'filled';
  @Trace cardType: ProxyDensity = 'standard';
  @Trace rowCount: number = 0;
  @Trace floating: number = 0;
  @Trace lift: number = 0;
  @Trace reveal: ProxyGroupReveal = new ProxyGroupReveal();
  readonly rows: KeyedListSource<ProxyNodeRow> = new KeyedListSource<ProxyNodeRow>();
  nodes: ProxyNodeView[] = [];
  allNodes: Map<string, ProxyNodeView> = new Map<string, ProxyNodeView>();

  constructor(profile: string, name: string) {
    this.profile = profile;
    this.key = JSON.stringify([profile, name]);
    this.name = name;
  }
}

export interface ProxyViewBuild {
  snapshot: ProxySnapshot;
  style: ProxyStyle;
  view: ProxyViewState;
  query: string;
  columns: number;
  latest: Map<string, number>;
  completedForGroup: (groupName: string) => Map<string, number>;
  phases: Map<string, ProxyDelayPhase>;
  pending: Map<string, ProxyPendingSelection>;
  testingGroups: Set<string>;
  previous: ProxyGroupView[];
  picker: boolean;
}

export function buildProxyViews(input: ProxyViewBuild): ProxyGroupView[] {
  const result: ProxyGroupView[] = [];
  for (const name of proxyGroupNames(input.snapshot)) {
    const source = input.snapshot.nodes[name];
    const members = proxyMembers(input.snapshot, source, input.query, input.style, input.completedForGroup(name));
    if (input.query.trim() !== '' && members.length === 0) {
      continue;
    }
    const group = input.previous.find((prior: ProxyGroupView): boolean => prior.name === name) ??
      new ProxyGroupView(input.snapshot.profile, name);
    group.type = source.type;
    group.now = source.now;
    group.actualRetired = proxyMemberNode(input.snapshot, name, source.nowId)?.retired ?? false;
    const savedPin = input.snapshot.selected[name] ?? '';
    const pinnedId = proxyPinnedMemberId(input.snapshot, source);
    group.pinned = ['URLTest', 'Fallback'].includes(source.type) ? savedPin : '';
    group.expanded = input.picker || input.view.expanded.includes(name);
    group.dynamic = source.dynamic;
    group.testing = input.testingGroups.has(name);
    group.icon = source.icon;
    group.iconStyle = input.style.iconStyle;
    group.cardType = input.style.cardType;
    const pending = input.pending.get(name);
    group.nodes = members.map((node: ProxyNodeSnapshot): ProxyNodeView => {
      let card = group.allNodes.get(node.id);
      if (card === undefined) {
        card = new ProxyNodeView(JSON.stringify([input.snapshot.profile, name, node.id]), node.id, node.name);
        group.allNodes.set(node.id, card);
      }
      const leaf = resolveProxyLeaf(input.snapshot, node.id, source.url, source.name);
      card.type = node.type;
      card.online = input.snapshot.online;
      card.addressable = node.selectable;
      card.selectable = node.selectable && selectableProxyGroup(source.type) &&
        (input.snapshot.online || input.snapshot.offlineWritable);
      card.leafName = leaf.resolved ? leaf.name : '';
      card.leafRetired = leaf.retired;
      card.nested = isProxyGroup(node.type);
      card.unresolved = !leaf.resolved;
      const normalized = input.snapshot.online || input.snapshot.memberNodes[source.name] !== undefined;
      card.selected = !node.missing && (normalized ? source.nowId : source.now) === node.id;
      card.pinned = !node.missing && pinnedId === node.id && ['URLTest', 'Fallback'].includes(source.type);
      card.pending = pending !== undefined && !pending.clearPin && pending.target === node.id;
      const leafNode = proxyMemberNode(input.snapshot, leaf.group, leaf.id);
      card.testable = input.snapshot.online && leaf.resolved && !leaf.retired && leafNode !== undefined && canTestProxy(leafNode);
      card.delayKey = leaf.resolved ? proxyDelayKey(input.snapshot, leaf) : '';
      card.delay = input.latest.get(card.delayKey) ?? 0;
      card.phase = input.phases.get(card.delayKey) ?? 'idle';
      return card;
    });
    const present = new Set<string>(source.members);
    group.allNodes.forEach((_card: ProxyNodeView, nodeName: string): void => {
      if (!present.has(nodeName)) {
        group.allNodes.delete(nodeName);
      }
    });
    const previousRows = group.rows.values();
    const rows: ProxyNodeRow[] = [];
    if (group.expanded) {
      for (let index = 0; index < group.nodes.length; index += input.columns) {
        let rowKey = `${group.key}.${input.columns}`;
        for (let position = index; position < Math.min(index + input.columns, group.nodes.length); position++) {
          const id = group.nodes[position].id;
          rowKey += `.${id.length}:${id}`;
        }
        const previousRow = previousRows[rows.length];
        rows.push(previousRow !== undefined && previousRow.key === rowKey &&
          previousRow.nodes.length === Math.min(input.columns, group.nodes.length - index) &&
          previousRow.nodes.every((card: ProxyNodeView, position: number): boolean => card === group.nodes[index + position]) ?
          previousRow : new ProxyNodeRow(rowKey, group.nodes.slice(index, index + input.columns), input.columns));
        rows[rows.length - 1].last = index + input.columns >= group.nodes.length;
      }
    }
    group.rowCount = rows.length;
    group.rows.replace(rows);
    result.push(group);
  }
  return result;
}

export function applyProxyDelayViews(groups: ProxyGroupView[], latest: Map<string, number>,
  phases: Map<string, ProxyDelayPhase>, testingGroups: Set<string>): void {
  for (const group of groups) {
    group.testing = testingGroups.has(group.name);
    for (const card of group.nodes) {
      card.delay = latest.get(card.delayKey) ?? 0;
      card.phase = phases.get(card.delayKey) ?? 'idle';
    }
  }
}
