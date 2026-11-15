import {
  cancelProxyDelayOwner, ProxyDelayPhase, ProxyDelayTarget, ProxyDelayUpdate,
  proxyMemberNode, ProxyNodeSnapshot, ProxySnapshot, testProxyDelays
} from '../../client/Proxies';
import { newId } from '../../shared/profiles/Store';
import {
  canTestProxy, defaultProxyStyle, proxyDelayKey, proxyGroupNames, proxyMembers, resolveProxyLeaf
} from './ProxyLogic';

const DELAY_FLUSH_MS = 300;
const MAX_DELAY_RESULTS = 8192;

export class ProxyTestSession {
  readonly latest: Map<string, number> = new Map<string, number>();
  readonly completed: Map<string, number> = new Map<string, number>();
  readonly phases: Map<string, ProxyDelayPhase> = new Map<string, ProxyDelayPhase>();
  readonly testingGroups: Set<string> = new Set<string>();
  private owner: string = newId('proxy.page.');
  private activeBatches: Set<string> = new Set<string>();
  private buffered: Map<string, ProxyDelayUpdate> = new Map<string, ProxyDelayUpdate>();
  private groupHolds: Map<string, number> = new Map<string, number>();
  private frozenCompleted: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  private cacheOrder: string[] = [];
  private timer: number = -1;
  private generation: number = 0;
  private onChange: (rebuild: boolean) => void;
  private onNotice: (notice: string) => void;

  constructor(onChange: (rebuild: boolean) => void, onNotice: (notice: string) => void) {
    this.onChange = onChange;
    this.onNotice = onNotice;
  }

  completedFor(groupName: string): Map<string, number> {
    return this.frozenCompleted.get(groupName) ?? this.completed;
  }

  seed(snapshot: ProxySnapshot): void {
    if (this.activeBatches.size > 0) {
      return;
    }
    for (const name of proxyGroupNames(snapshot)) {
      const group = snapshot.nodes[name];
      for (const member of group.members) {
        const leaf = resolveProxyLeaf(snapshot, member, group.url, group.name);
        if (!leaf.resolved) {
          continue;
        }
        const key = proxyDelayKey(snapshot, leaf);
        const history = proxyMemberNode(snapshot, leaf.group, leaf.id)?.extra[leaf.url]?.history ?? [];
        const delay = history[history.length - 1]?.delay ?? 0;
        if (delay > 0 && !this.latest.has(key)) {
          this.remember(key, delay);
          this.completed.set(key, delay);
        }
      }
    }
  }

  start(filesDir: string, snapshot: ProxySnapshot, groupName: string, query: string,
    nodeName: string = ''): void {
    if (!snapshot.online) {
      this.onNotice('offline');
      return;
    }
    const group = snapshot.nodes[groupName];
    if (group === undefined) {
      return;
    }
    const batchKey = JSON.stringify([groupName, nodeName]);
    if (this.activeBatches.has(batchKey)) {
      return;
    }
    const members = nodeName === '' ? proxyMembers(snapshot, group, query, defaultProxyStyle(), this.completed) :
      group.members.filter((name: string): boolean => name === nodeName)
        .map((name: string): ProxyNodeSnapshot => proxyMemberNode(snapshot, group.name, name)!)
        .filter((node: ProxyNodeSnapshot): boolean => node !== undefined);
    const targets: Map<string, ProxyDelayTarget> = new Map<string, ProxyDelayTarget>();
    for (const member of members) {
      const leaf = resolveProxyLeaf(snapshot, member.id, group.url, group.name);
      const leafNode = proxyMemberNode(snapshot, leaf.group, leaf.id);
      if (leaf.resolved && !leaf.retired && leafNode !== undefined && canTestProxy(leafNode)) {
        const key = proxyDelayKey(snapshot, leaf);
        targets.set(key, {
          key: key, profile: snapshot.profile, name: leaf.name, id: leaf.id, group: leaf.group, url: leaf.url,
          expectedBootId: snapshot.bootId, expectedRevision: snapshot.configRevision
        });
      }
    }
    if (targets.size === 0) {
      this.onNotice('unresolved');
      return;
    }
    const generation = this.generation;
    const keys = Array.from<string>(targets.keys());
    this.holdGroup(snapshot, groupName);
    this.activeBatches.add(batchKey);
    if (nodeName === '') {
      this.testingGroups.add(groupName);
    }
    try {
      testProxyDelays(filesDir, this.owner, Array.from<ProxyDelayTarget>(targets.values()),
        (update: ProxyDelayUpdate): void => {
          if (generation === this.generation) {
            this.buffered.set(update.key, update);
            if (this.timer === -1) {
              this.timer = setTimeout((): void => this.flush(), DELAY_FLUSH_MS);
            }
          }
        }, (): void => {
          if (generation !== this.generation) {
            return;
          }
          this.flush();
          for (const key of keys) {
            const delay = this.latest.get(key);
            if (delay !== undefined) {
              this.completed.set(key, delay);
            }
          }
          this.activeBatches.delete(batchKey);
          if (nodeName === '') {
            this.testingGroups.delete(groupName);
          }
          this.releaseGroup(groupName);
          this.onChange(true);
        });
      this.onChange(false);
    } catch (e) {
      this.activeBatches.delete(batchKey);
      if (nodeName === '') {
        this.testingGroups.delete(groupName);
      }
      this.releaseGroup(groupName);
      this.onNotice('capacity');
      this.onChange(false);
    }
  }

  cancel(clearResults: boolean = false): void {
    this.generation++;
    cancelProxyDelayOwner(this.owner);
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.buffered.clear();
    this.phases.clear();
    this.activeBatches.clear();
    this.testingGroups.clear();
    this.groupHolds.clear();
    this.frozenCompleted.clear();
    if (clearResults) {
      this.latest.clear();
      this.completed.clear();
      this.cacheOrder = [];
    }
    this.onChange(false);
  }

  private flush(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    let noConclusion = false;
    this.buffered.forEach((update: ProxyDelayUpdate): void => {
      if (update.phase === 'idle') {
        this.phases.delete(update.key);
      } else {
        this.phases.set(update.key, update.phase);
      }
      if (update.delay !== undefined) {
        this.remember(update.key, update.delay);
      }
      noConclusion = noConclusion || update.noConclusion;
    });
    this.buffered.clear();
    if (noConclusion) {
      this.onNotice('noConclusion');
    }
    this.onChange(false);
  }

  private holdGroup(snapshot: ProxySnapshot, groupName: string): void {
    const holds = this.groupHolds.get(groupName) ?? 0;
    if (holds === 0) {
      const frozen: Map<string, number> = new Map<string, number>();
      const group = snapshot.nodes[groupName];
      for (const member of group.members) {
        const leaf = resolveProxyLeaf(snapshot, member, group.url, group.name);
        if (leaf.resolved) {
          const key = proxyDelayKey(snapshot, leaf);
          const delay = this.completed.get(key);
          if (delay !== undefined) {
            frozen.set(key, delay);
          }
        }
      }
      this.frozenCompleted.set(groupName, frozen);
    }
    this.groupHolds.set(groupName, holds + 1);
  }

  private releaseGroup(groupName: string): void {
    const holds = this.groupHolds.get(groupName) ?? 0;
    if (holds > 1) {
      this.groupHolds.set(groupName, holds - 1);
    } else {
      this.groupHolds.delete(groupName);
      this.frozenCompleted.delete(groupName);
    }
  }

  private remember(key: string, delay: number): void {
    if (!this.latest.has(key)) {
      this.cacheOrder.push(key);
    }
    this.latest.set(key, delay);
    if (this.cacheOrder.length > MAX_DELAY_RESULTS) {
      const oldest = this.cacheOrder.shift();
      if (oldest !== undefined) {
        this.latest.delete(oldest);
        this.completed.delete(oldest);
      }
    }
  }
}
