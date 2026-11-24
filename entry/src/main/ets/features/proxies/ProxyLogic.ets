import { isProxyGroup, proxyMemberNode, ProxyNodeSnapshot, ProxySnapshot, PROXY_TEST_URL } from '../../client/Proxies';

export type ProxySort = 'none' | 'name' | 'delay';
export type ProxyDensity = 'loose' | 'standard' | 'compact';
export type ProxyIconStyle = 'filled' | 'icon' | 'hidden';

export interface ProxyStyle {
  sortType: ProxySort;
  layout: ProxyDensity;
  cardType: ProxyDensity;
  iconStyle: ProxyIconStyle;
  hideTimeoutProxies: boolean;
}

export interface ProxyViewState {
  expanded: string[];
  currentGroup: string;
}

export interface ProxyLeaf {
  id: string;
  name: string;
  type: string;
  url: string;
  group: string;
  provider: string;
  resolved: boolean;
  retired: boolean;
  reason: '' | 'cycle' | 'missing' | 'unselected';
}

export interface ProxyDelayDisplay {
  kind: 'untested' | 'success' | 'warning' | 'timeout' | 'failed';
  delay: number;
}

export function defaultProxyStyle(): ProxyStyle {
  return {
    sortType: 'none', layout: 'standard', cardType: 'standard',
    iconStyle: 'filled', hideTimeoutProxies: false
  };
}

export function copyProxyStyle(style: ProxyStyle): ProxyStyle {
  return {
    sortType: style.sortType, layout: style.layout, cardType: style.cardType,
    iconStyle: style.iconStyle, hideTimeoutProxies: style.hideTimeoutProxies
  };
}

function validProxyTestUrl(candidate: string): boolean {
  return new RegExp('^https?://[^\\s/]+(?:/[^\\s]*)?$').test(candidate);
}

export function proxyTestUrl(candidate: string, fallback: string = PROXY_TEST_URL): string {
  if (validProxyTestUrl(candidate)) {
    return candidate;
  }
  return validProxyTestUrl(fallback) ? fallback : PROXY_TEST_URL;
}

export function proxyMatches(node: ProxyNodeSnapshot, query: string): boolean {
  const words = query.trim().toLowerCase().split(new RegExp('\\s+')).filter((word: string): boolean => word !== '');
  const haystack = `${node.name}\n${node.type}`.toLowerCase();
  return words.every((word: string): boolean => haystack.includes(word));
}

export function resolveProxyLeaf(snapshot: ProxySnapshot, name: string, groupUrl: string,
  groupName: string = '', defaultTestUrl: string = PROXY_TEST_URL): ProxyLeaf {
  const seen: Set<string> = new Set<string>();
  let cursor = name;
  let owner = groupName;
  let url = proxyTestUrl(groupUrl, defaultTestUrl);
  let retired = false;
  while (cursor !== '') {
    const identity = JSON.stringify([owner, cursor]);
    if (seen.has(identity)) {
      return { id: cursor, name: cursor, type: '', url: url, group: owner, provider: '', resolved: false, retired: retired, reason: 'cycle' };
    }
    seen.add(identity);
    const node = proxyMemberNode(snapshot, owner, cursor);
    if (node === undefined || node.missing) {
      return { id: cursor, name: cursor, type: '', url: url, group: owner, provider: '', resolved: false, retired: retired, reason: 'missing' };
    }
    retired = retired || node.retired;
    if (!isProxyGroup(node.type)) {
      return {
        id: node.id, name: node.name, type: node.type, url: url, group: owner, provider: node.provider,
        resolved: true, retired: retired, reason: ''
      };
    }
    if (node.url !== '') {
      url = proxyTestUrl(node.url, defaultTestUrl);
    }
    owner = node.name;
    cursor = snapshot.online || snapshot.memberNodes[node.name] !== undefined ? node.nowId : node.now;
  }
  return { id: '', name: '', type: '', url: url, group: owner, provider: '', resolved: false, retired: retired, reason: 'unselected' };
}

export function proxyDelayKey(snapshot: ProxySnapshot, leaf: ProxyLeaf): string {
  return JSON.stringify([snapshot.profile, snapshot.bootId, snapshot.configRevision, snapshot.revision, leaf.url, leaf.id]);
}

export function proxyDelayDisplay(delay: number): ProxyDelayDisplay {
  if (delay > 0) {
    return { kind: delay < 600 ? 'success' : 'warning', delay: delay };
  }
  if (delay === -1) {
    return { kind: 'timeout', delay: delay };
  }
  if (delay === -2) {
    return { kind: 'failed', delay: delay };
  }
  return { kind: 'untested', delay: 0 };
}

export function canTestProxy(node: ProxyNodeSnapshot): boolean {
  return !node.missing && !node.retired && !['Reject', 'RejectDrop', 'Pass', 'PassRule', 'Rematch', 'Compatible', 'Dns']
    .includes(node.type);
}

export function selectableProxyGroup(type: string): boolean {
  return ['Selector', 'URLTest', 'Fallback'].includes(type);
}

export function proxyPinnedMemberId(snapshot: ProxySnapshot, group: ProxyNodeSnapshot): string {
  const saved = snapshot.selected[group.name] ?? '';
  return group.members.find((id: string): boolean => {
    const node = proxyMemberNode(snapshot, group.name, id);
    return node !== undefined && node.name === saved && node.selectable;
  }) ?? '';
}

export interface ProxySelectionIntent {
  changed: boolean;
  clearPin: boolean;
  name: string;
}

export function proxySelectionIntent(type: string, current: string, target: string): ProxySelectionIntent {
  if (!selectableProxyGroup(type)) {
    return { changed: false, clearPin: false, name: '' };
  }
  const clearPin = type !== 'Selector' && current === target;
  return { changed: type !== 'Selector' || current !== target, clearPin: clearPin, name: clearPin ? '' : target };
}

export function proxyGroupNames(snapshot: ProxySnapshot): string[] {
  if (snapshot.mode === 'direct') {
    return [];
  }
  return snapshot.groups.filter((name: string): boolean => {
    const group = snapshot.nodes[name];
    return group !== undefined && (snapshot.mode === 'global' || (name !== 'GLOBAL' && !group.hidden));
  });
}

function delayLayer(delay: number): number {
  if (delay > 0) {
    return 0;
  }
  if (delay === -1) {
    return 2;
  }
  if (delay === -2) {
    return 3;
  }
  return 1;
}

export function proxyMemberDelay(snapshot: ProxySnapshot, group: ProxyNodeSnapshot, name: string,
  delays: Map<string, number>, defaultTestUrl: string = PROXY_TEST_URL): number {
  const leaf = resolveProxyLeaf(snapshot, name, group.url, group.name, defaultTestUrl);
  return leaf.resolved ? delays.get(proxyDelayKey(snapshot, leaf)) ?? 0 : 0;
}

export function proxyMembers(snapshot: ProxySnapshot, group: ProxyNodeSnapshot, query: string,
  style: ProxyStyle, completed: Map<string, number>, defaultTestUrl: string = PROXY_TEST_URL): ProxyNodeSnapshot[] {
  const matches: ProxyNodeSnapshot[] = [];
  for (const name of group.members) {
    const node = proxyMemberNode(snapshot, group.name, name);
    const member: ProxyNodeSnapshot = node ?? {
      id: name, selectable: false, nowId: '', retired: false, name: name, type: '', now: '', members: [], hidden: false, url: '', icon: '',
      dynamic: false, missing: true, extra: {}, provider: ''
    };
    if (proxyMatches(member, query)) {
      matches.push(member);
    }
  }
  let visible = matches;
  if (style.hideTimeoutProxies) {
    const selected = proxyPinnedMemberId(snapshot, group);
    const normalized = snapshot.online || snapshot.memberNodes[group.name] !== undefined;
    const actual = normalized ? group.nowId : group.now;
    const filtered = matches.filter((node: ProxyNodeSnapshot): boolean => {
      if (node.id === selected || node.id === actual || isProxyGroup(node.type) || !canTestProxy(node)) {
        return true;
      }
      const delay = proxyMemberDelay(snapshot, group, node.id, completed, defaultTestUrl);
      return delay >= 0;
    });
    if (filtered.length > 0) {
      visible = filtered;
    }
  }
  if (style.sortType === 'name') {
    visible.sort((left: ProxyNodeSnapshot, right: ProxyNodeSnapshot): number =>
      left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  } else if (style.sortType === 'delay') {
    const order: Map<string, number> = new Map<string, number>();
    group.members.forEach((name: string, index: number): void => { order.set(name, index); });
    visible.sort((left: ProxyNodeSnapshot, right: ProxyNodeSnapshot): number => {
      const leftDelay = proxyMemberDelay(snapshot, group, left.id, completed, defaultTestUrl);
      const rightDelay = proxyMemberDelay(snapshot, group, right.id, completed, defaultTestUrl);
      const layer = delayLayer(leftDelay) - delayLayer(rightDelay);
      if (layer !== 0) {
        return layer;
      }
      if (leftDelay > 0 && rightDelay > 0 && leftDelay !== rightDelay) {
        return leftDelay - rightDelay;
      }
      return (order.get(left.id) ?? 0) - (order.get(right.id) ?? 0);
    });
  }
  return visible;
}

export function proxyColumnCount(availableWidth: number, density: ProxyDensity): number {
  const standard = Math.max(2, Math.ceil(availableWidth / 250));
  return Math.max(1, standard + (density === 'loose' ? -1 : density === 'compact' ? 1 : 0));
}

export function validProxyView(saved: ProxyViewState, names: string[], mode: string): ProxyViewState {
  return {
    expanded: saved.expanded.filter((name: string): boolean => names.includes(name)),
    currentGroup: names.includes(saved.currentGroup) ? saved.currentGroup :
      mode === 'global' && names.includes('GLOBAL') ? 'GLOBAL' : names[0] ?? ''
  };
}
