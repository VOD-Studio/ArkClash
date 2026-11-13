import { http } from '@kit.NetworkKit';
import { ProfileSummary, SummaryGroup } from '../shared/profiles/Summary';
import { newId, readSelected, writeSelected } from '../shared/profiles/Store';
import { CONTROLLER_ADDRESS, readRuntime } from '../shared/Runtime';
import { call, getMode, OutboundMode, RuntimeStatus } from './Controller';

export const PROXY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const PROXY_TEST_TIMEOUT = 8000;
const MAX_ACTIVE_TESTS = 8;
const MAX_QUEUED_TESTS = 2048;

export interface ProxyDelayHistory {
  delay: number;
}

export interface ProxyUrlHistory {
  history?: ProxyDelayHistory[];
}

interface ProxyWireNode {
  type?: string;
  now?: string;
  all?: string[];
  hidden?: boolean;
  testUrl?: string;
  url?: string;
  icon?: string;
  extra?: Record<string, ProxyUrlHistory>;
  name?: string;
}

interface ProxyWireResponse {
  proxies?: Record<string, ProxyMemberReference>;
  nodes?: Record<string, ProxyWireNode>;
  members?: Record<string, ProxyMemberReference[]>;
  actual?: Record<string, string>;
  retired?: Record<string, boolean>;
}

interface ProxyMemberReference {
  id: string;
  name: string;
  provider?: string;
  selectable: boolean;
}

interface ProxySelectionsResponse {
  profile: string;
  selected: Record<string, string>;
}

export interface ProxyNodeSnapshot {
  id: string;
  selectable: boolean;
  nowId: string;
  retired: boolean;
  name: string;
  type: string;
  now: string;
  members: string[];
  hidden: boolean;
  url: string;
  icon: string;
  dynamic: boolean;
  missing: boolean;
  extra: Record<string, ProxyUrlHistory>;
  provider: string;
}

export interface ProxySnapshot {
  profile: string;
  bootId: string;
  revision: string;
  configRevision: number;
  online: boolean;
  offlineWritable: boolean;
  mode: OutboundMode;
  nodes: Record<string, ProxyNodeSnapshot>;
  memberNodes: Record<string, Record<string, ProxyNodeSnapshot>>;
  actualNodes: Record<string, ProxyNodeSnapshot>;
  groups: string[];
  selected: Record<string, string>;
}

interface ProxyStructure {
  id: string;
  selectable: boolean;
  name: string;
  type: string;
  members: string[];
  url: string;
  hidden: boolean;
  provider: string;
}

export interface ProxySelectionCommand {
  profile: string;
  group: string;
  name: string;
  nodeId: string;
  clearPin: boolean;
  closeConnections: boolean;
  operationId: string;
  expectedBootId: string;
  expectedRevision: number;
}

export interface ProxySelectionResult {
  changed: boolean;
  selected: string;
  selectedId: string;
  pinned: string;
  cleanupFailed: boolean;
}

export interface ProxySelectionChange {
  command: ProxySelectionCommand;
  result: ProxySelectionResult;
  identity: ProxySelectionIdentity;
}

export interface ProxySelectionIdentity {
  profile: string;
  bootId: string;
  revision: string;
  configRevision: number;
  online: boolean;
  offlineWritable: boolean;
}

export function proxySelectionIdentity(snapshot: ProxySnapshot): ProxySelectionIdentity {
  return {
    profile: snapshot.profile, bootId: snapshot.bootId, revision: snapshot.revision,
    configRevision: snapshot.configRevision, online: snapshot.online, offlineWritable: snapshot.offlineWritable
  };
}

export function matchesProxySelectionIdentity(snapshot: ProxySnapshot, identity: ProxySelectionIdentity): boolean {
  return snapshot.profile === identity.profile && snapshot.bootId === identity.bootId &&
    snapshot.revision === identity.revision && snapshot.configRevision === identity.configRevision &&
    snapshot.online === identity.online && snapshot.offlineWritable === identity.offlineWritable;
}

export function canonicalProxyType(type: string): string {
  switch (type.toLowerCase().replace(new RegExp('[-_]', 'g'), '')) {
    case 'select':
    case 'selector': return 'Selector';
    case 'urltest': return 'URLTest';
    case 'fallback': return 'Fallback';
    case 'loadbalance': return 'LoadBalance';
    case 'relay': return 'Relay';
    default: return type;
  }
}

export function isProxyGroup(type: string): boolean {
  return ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay'].includes(canonicalProxyType(type));
}

function emptyProxyNode(name: string, type: string = ''): ProxyNodeSnapshot {
  return {
    id: name, selectable: true, nowId: '', retired: false,
    name: name, type: canonicalProxyType(type), now: '', members: [], hidden: false,
    url: '', icon: '', dynamic: false, missing: false, extra: {}, provider: ''
  };
}

function snapshotRevision(profile: string, summary: ProfileSummary | undefined,
  nodes: Record<string, ProxyNodeSnapshot>, memberNodes: Record<string, Record<string, ProxyNodeSnapshot>>): string {
  const structures: ProxyStructure[] = Object.keys(nodes).map((name: string): ProxyStructure => {
    const node = nodes[name];
    return {
      id: node.id, selectable: node.selectable,
      name: name, type: node.type, members: node.members, url: node.url, hidden: node.hidden, provider: node.provider
    };
  });
  const providers: Record<string, ProxyStructure[]> = {};
  for (const group of Object.keys(memberNodes)) {
    providers[group] = Object.keys(memberNodes[group]).map((name: string): ProxyStructure => {
      const node = memberNodes[group][name];
      return {
        id: node.id, selectable: node.selectable,
        name: name, type: node.type, members: node.members, url: node.url, hidden: node.hidden, provider: node.provider
      };
    });
  }
  const content = JSON.stringify([profile, summary?.revision ?? '', structures, providers]);
  let first = 2166136261;
  let second = 5381;
  for (let index = 0; index < content.length; index++) {
    first = Math.imul(first ^ content.charCodeAt(index), 16777619);
    second = Math.imul(second, 33) ^ content.charCodeAt(index);
  }
  return `${(first >>> 0).toString(16)}.${(second >>> 0).toString(16)}`;
}

export function offlineProxySnapshot(profile: string, summary: ProfileSummary, selected: Record<string, string>,
  mode: OutboundMode, offlineWritable: boolean): ProxySnapshot {
  const nodes: Record<string, ProxyNodeSnapshot> = {};
  for (const definition of summary.nodes ?? []) {
    nodes[definition.name] = emptyProxyNode(definition.name, definition.type);
  }
  for (const builtin of ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS']) {
    if (nodes[builtin] === undefined) {
      nodes[builtin] = emptyProxyNode(builtin, builtin === 'DIRECT' ? 'Direct' : 'Reject');
    }
  }
  for (const group of summary.groups) {
    const node = emptyProxyNode(group.name, group.type);
    node.members = group.members.slice();
    node.hidden = group.hidden ?? false;
    node.url = group.url ?? '';
    node.icon = group.icon ?? '';
    node.dynamic = group.dynamic;
    if (node.type === 'Selector') {
      const saved = selected[group.name] ?? '';
      node.now = node.members.includes(saved) ? saved : node.members[0] ?? '';
      node.nowId = node.now;
    }
    nodes[group.name] = node;
    for (const member of group.members) {
      if (nodes[member] === undefined) {
        nodes[member] = emptyProxyNode(member);
      }
    }
  }
  if (mode === 'global' && nodes['GLOBAL'] === undefined) {
    const global = emptyProxyNode('GLOBAL', 'Selector');
    global.members = summary.groups.map((group: SummaryGroup): string => group.name);
    for (const definition of summary.nodes ?? []) {
      if (!global.members.includes(definition.name)) {
        global.members.push(definition.name);
      }
    }
    global.now = selected['GLOBAL'] ?? global.members[0] ?? '';
    global.nowId = global.now;
    nodes['GLOBAL'] = global;
  }
  const groups = summary.groups.map((group: SummaryGroup): string => group.name);
  if (mode === 'global' && !groups.includes('GLOBAL')) {
    groups.unshift('GLOBAL');
  }
  return {
    profile: profile, bootId: '', revision: snapshotRevision(profile, summary, nodes, {}), configRevision: 0,
    online: false, offlineWritable: offlineWritable, mode: mode, memberNodes: {}, actualNodes: {},
    nodes: nodes, groups: groups, selected: selected
  };
}

export async function readOfflineProxies(filesDir: string, profile: string, summary: ProfileSummary,
  mode: OutboundMode, offlineWritable: boolean): Promise<ProxySnapshot> {
  return offlineProxySnapshot(profile, summary, await readSelected(filesDir, profile), mode, offlineWritable);
}

export function proxyMemberNode(snapshot: ProxySnapshot, group: string, name: string): ProxyNodeSnapshot | undefined {
  const members = snapshot.memberNodes[group];
  const member = members === undefined ? snapshot.nodes[name] : members[name];
  if (member !== undefined) {
    return member;
  }
  const actual = snapshot.actualNodes[group];
  return actual?.id === name ? actual : undefined;
}

function proxyWireNode(ref: ProxyMemberReference, wire: ProxyWireNode): ProxyNodeSnapshot {
  const node = emptyProxyNode(ref.name, wire.type ?? '');
  node.id = ref.id;
  node.selectable = ref.selectable;
  node.now = wire.now ?? '';
  node.members = wire.all ?? [];
  node.hidden = wire.hidden ?? false;
  node.url = wire.testUrl ?? wire.url ?? '';
  node.icon = wire.icon ?? '';
  node.extra = wire.extra ?? {};
  node.provider = ref.provider ?? '';
  return node;
}

export async function readOnlineProxies(filesDir: string, profile: string,
  summary: ProfileSummary | undefined): Promise<ProxySnapshot> {
  const before = JSON.parse(await call(filesDir, http.RequestMethod.GET, '/arkclash/status')) as RuntimeStatus;
  if (before.profile !== profile) {
    throw new Error('proxy_profile_changed');
  }
  const replies = await Promise.all<string>([
    call(filesDir, http.RequestMethod.GET, '/arkclash/proxies'),
    call(filesDir, http.RequestMethod.GET, '/arkclash/selections'),
    getMode(filesDir)
  ]);
  const raw = JSON.parse(replies[0]) as ProxyWireResponse;
  const selections = JSON.parse(replies[1]) as ProxySelectionsResponse;
  const after = JSON.parse(await call(filesDir, http.RequestMethod.GET, '/arkclash/status')) as RuntimeStatus;
  if (selections.profile !== profile || after.profile !== profile || before.bootId !== after.bootId ||
    before.revision !== after.revision || raw.proxies === undefined || raw.nodes === undefined ||
    raw.members === undefined || raw.actual === undefined || selections.selected === undefined) {
    throw new Error('proxy_snapshot_changed');
  }
  const nodes: Record<string, ProxyNodeSnapshot> = {};
  for (const name of Object.keys(raw.proxies)) {
    const ref = raw.proxies[name];
    const wire = raw.nodes[ref.id];
    if (wire === undefined || ref.name !== name) {
      throw new Error('proxy_snapshot_changed');
    }
    nodes[name] = proxyWireNode(ref, wire);
  }
  const memberNodes: Record<string, Record<string, ProxyNodeSnapshot>> = {};
  for (const group of Object.keys(raw.members)) {
    const members: Record<string, ProxyNodeSnapshot> = {};
    for (const ref of raw.members[group]) {
      const wire = raw.nodes[ref.id];
      if (wire === undefined || wire.name !== ref.name || members[ref.id] !== undefined) {
        throw new Error('proxy_snapshot_changed');
      }
      const node = proxyWireNode(ref, wire);
      const definition = nodes[ref.name];
      if (definition !== undefined && definition.id === ref.id) {
        node.members = definition.members;
      }
      members[ref.id] = node;
    }
    memberNodes[group] = members;
    const source = nodes[group];
    if (source !== undefined) {
      source.members = raw.members[group].map((ref: ProxyMemberReference): string => ref.id);
      source.nowId = raw.actual[group] ?? '';
      source.now = raw.nodes[source.nowId]?.name ?? '';
    }
  }
  const actualNodes: Record<string, ProxyNodeSnapshot> = {};
  for (const group of Object.keys(raw.actual)) {
    const id = raw.actual[group];
    if (id === '') {
      continue;
    }
    const wire = raw.nodes[id];
    if (nodes[group] === undefined || wire?.name === undefined || wire.name === '') {
      throw new Error('proxy_snapshot_changed');
    }
    const member = memberNodes[group]?.[id];
    const ref: ProxyMemberReference = { id: id, name: wire.name, selectable: false };
    const actual = member ?? proxyWireNode(ref, wire);
    actual.retired = raw.retired?.[id] === true;
    actual.selectable = actual.selectable && !actual.retired;
    actualNodes[group] = actual;
  }
  for (const group of Object.keys(memberNodes)) {
    for (const id of Object.keys(memberNodes[group])) {
      const node = memberNodes[group][id];
      const definition = nodes[node.name];
      if (definition !== undefined && definition.id === id) {
        node.members = definition.members;
        node.now = definition.now;
        node.nowId = definition.nowId;
      }
    }
  }
  const order = summary?.groups.map((group: SummaryGroup): string => group.name) ?? [];
  for (const name of Object.keys(nodes)) {
    if (!order.includes(name)) {
      order.push(name);
    }
  }
  for (const name of Object.keys(nodes)) {
    if (isProxyGroup(nodes[name].type) && !order.includes(name)) {
      order.push(name);
    }
  }
  const groups = order.filter((name: string): boolean => nodes[name] !== undefined && isProxyGroup(nodes[name].type));
  if (replies[2] === 'global' && groups.includes('GLOBAL')) {
    groups.splice(groups.indexOf('GLOBAL'), 1);
    groups.unshift('GLOBAL');
  }
  return {
    profile: profile, bootId: after.bootId,
    revision: `${after.bootId}/${snapshotRevision(profile, summary, nodes, memberNodes)}`,
    memberNodes: memberNodes, actualNodes: actualNodes,
    configRevision: after.configRevision, online: true, offlineWritable: false,
    mode: replies[2] as OutboundMode, nodes: nodes, groups: groups, selected: selections.selected
  };
}

const selectionQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();
const selectionOperations: Map<string, Promise<ProxySelectionResult>> = new Map<string, Promise<ProxySelectionResult>>();
const selectionListeners: Set<(change: ProxySelectionChange) => void> = new Set<(change: ProxySelectionChange) => void>();

export function observeProxySelections(listener: (change: ProxySelectionChange) => void): () => void {
  selectionListeners.add(listener);
  return (): void => { selectionListeners.delete(listener); };
}

export async function flushProxySelections(filesDir: string): Promise<void> {
  const pending: Promise<ProxySelectionResult>[] = [];
  selectionOperations.forEach((promise: Promise<ProxySelectionResult>, key: string): void => {
    if (key.startsWith(`${filesDir}\u0000`)) {
      pending.push(promise);
    }
  });
  await Promise.all<ProxySelectionResult>(pending);
}

export async function submitProxySelection(filesDir: string, command: ProxySelectionCommand,
  group: ProxyNodeSnapshot, identity: ProxySelectionIdentity, stillCurrent: () => boolean): Promise<ProxySelectionResult> {
  if (identity.profile !== command.profile || (!identity.online && !identity.offlineWritable)) {
    throw new Error('proxy_selection_stale');
  }
  if (!['Selector', 'URLTest', 'Fallback'].includes(group.type) ||
    (!command.clearPin && !group.members.includes(command.nodeId)) ||
    (command.clearPin && group.type === 'Selector')) {
    throw new Error('proxy_selection_unsupported');
  }
  const queueKey = `${filesDir}\u0000${command.profile}`;
  const previous = selectionQueues.get(queueKey) ?? Promise.resolve();
  const operation = previous.then(async (): Promise<ProxySelectionResult> => {
    if (!stillCurrent() || (!identity.online && !identity.offlineWritable)) {
      throw new Error('proxy_selection_stale');
    }
    let result: ProxySelectionResult;
    if (identity.online) {
      result = JSON.parse(await call(filesDir, http.RequestMethod.POST, '/arkclash/selection',
        JSON.stringify(command), 15000)) as ProxySelectionResult;
      if (typeof result.changed !== 'boolean' || typeof result.selected !== 'string' ||
        typeof result.selectedId !== 'string' || typeof result.pinned !== 'string' || typeof result.cleanupFailed !== 'boolean') {
        throw new Error('proxy_selection_response');
      }
    } else {
      let selected = await readSelected(filesDir, command.profile);
      if (!stillCurrent() || !identity.offlineWritable) {
        throw new Error('proxy_selection_stale');
      }
      const target = command.clearPin ? '' : command.name;
      const changed = (selected[command.group] ?? '') !== target;
      if (target === '') {
        const retained: Record<string, string> = {};
        for (const name of Object.keys(selected)) {
          if (name !== command.group) { retained[name] = selected[name]; }
        }
        selected = retained;
      } else {
        selected[command.group] = target;
      }
      if (changed) {
        await writeSelected(filesDir, command.profile, selected,
          (): boolean => !identity.online && identity.offlineWritable && stillCurrent());
      }
      result = {
        changed: changed, selected: group.type === 'Selector' ? target : '',
        selectedId: group.type === 'Selector' ? command.nodeId : '',
        pinned: group.type === 'Selector' ? '' : target, cleanupFailed: false
      };
    }
    if (!stillCurrent()) {
      throw new Error('proxy_selection_stale');
    }
    const change: ProxySelectionChange = { command: command, result: result, identity: identity };
    for (const listener of selectionListeners) {
      listener(change);
    }
    return result;
  });
  const settled = operation.then((): void => {}, (): void => {});
  selectionQueues.set(queueKey, settled);
  const operationKey = `${queueKey}\u0000${command.operationId}`;
  selectionOperations.set(operationKey, operation);
  settled.then((): void => {
    if (selectionQueues.get(queueKey) === settled) {
      selectionQueues.delete(queueKey);
    }
    selectionOperations.delete(operationKey);
  });
  return await operation;
}

export type ProxyDelayPhase = 'idle' | 'queued' | 'running';

export interface ProxyDelayTarget {
  key: string;
  profile: string;
  name: string;
  id: string;
  expectedBootId: string;
  expectedRevision: number;
  group: string;
  url: string;
}

export interface ProxyDelayUpdate {
  key: string;
  phase: ProxyDelayPhase;
  delay?: number;
  noConclusion: boolean;
}

export class ProxyDelayBatch {
  id: string = newId('delay.');
  owner: string;
  pending: Set<string> = new Set<string>();
  cancelled: boolean = false;
  onUpdate: (update: ProxyDelayUpdate) => void;
  onFinish: () => void;

  constructor(owner: string, onUpdate: (update: ProxyDelayUpdate) => void, onFinish: () => void) {
    this.owner = owner;
    this.onUpdate = onUpdate;
    this.onFinish = onFinish;
  }
}

class ProxyDelayJob {
  target: ProxyDelayTarget;
  filesDir: string;
  phase: ProxyDelayPhase = 'queued';
  batches: Map<string, ProxyDelayBatch> = new Map<string, ProxyDelayBatch>();
  request?: http.HttpRequest;
  cancelled: boolean = false;

  constructor(filesDir: string, target: ProxyDelayTarget) {
    this.filesDir = filesDir;
    this.target = target;
  }
}

interface ProxyDelayWireResult {
  delay?: number;
}

export function proxyDelayResponse(status: number, text: string): number | undefined {
  if (status === 200) {
    const result = JSON.parse(text) as ProxyDelayWireResult;
    return typeof result.delay === 'number' && result.delay > 0 ? result.delay : undefined;
  }
  if (status === 504) {
    return -1;
  }
  return status === 503 ? -2 : undefined;
}

class ProxyDelayScheduler {
  private jobs: Map<string, ProxyDelayJob> = new Map<string, ProxyDelayJob>();
  private queue: ProxyDelayJob[] = [];
  private active: number = 0;
  private batches: Map<string, ProxyDelayBatch> = new Map<string, ProxyDelayBatch>();

  start(filesDir: string, owner: string, targets: ProxyDelayTarget[],
    onUpdate: (update: ProxyDelayUpdate) => void, onFinish: () => void): ProxyDelayBatch {
    const batch = new ProxyDelayBatch(owner, onUpdate, onFinish);
    const unique: Map<string, ProxyDelayTarget> = new Map<string, ProxyDelayTarget>();
    for (const target of targets) {
      unique.set(target.key, target);
    }
    let fresh = 0;
    unique.forEach((_target: ProxyDelayTarget, key: string): void => {
      if (!this.jobs.has(key)) {
        fresh++;
      }
    });
    if (this.queue.length + fresh > MAX_QUEUED_TESTS) {
      throw new Error('proxy_delay_capacity');
    }
    this.batches.set(batch.id, batch);
    unique.forEach((target: ProxyDelayTarget, key: string): void => {
      let job = this.jobs.get(key);
      if (job === undefined) {
        job = new ProxyDelayJob(filesDir, target);
        this.jobs.set(key, job);
        this.queue.push(job);
      }
      batch.pending.add(key);
      job.batches.set(batch.id, batch);
      batch.onUpdate({ key: key, phase: job.phase, noConclusion: false });
    });
    if (batch.pending.size === 0) {
      Promise.resolve().then((): void => this.finishBatch(batch));
    }
    this.pump();
    return batch;
  }

  cancelOwner(owner: string): void {
    const owned: ProxyDelayBatch[] = [];
    this.batches.forEach((batch: ProxyDelayBatch): void => {
      if (batch.owner === owner) {
        owned.push(batch);
      }
    });
    for (const batch of owned) {
      batch.cancelled = true;
      for (const key of batch.pending) {
        const job = this.jobs.get(key);
        job?.batches.delete(batch.id);
        if (job !== undefined && job.batches.size === 0) {
          job.cancelled = true;
          job.request?.destroy();
          this.jobs.delete(key);
        }
      }
      batch.pending.clear();
      this.batches.delete(batch.id);
    }
    this.queue = this.queue.filter((job: ProxyDelayJob): boolean => !job.cancelled);
  }

  private pump(): void {
    while (this.active < MAX_ACTIVE_TESTS && this.queue.length > 0) {
      const job = this.queue.shift();
      if (job === undefined || job.cancelled) {
        continue;
      }
      this.active++;
      job.phase = 'running';
      job.batches.forEach((batch: ProxyDelayBatch): void => {
        batch.onUpdate({ key: job.target.key, phase: 'running', noConclusion: false });
      });
      this.execute(job);
    }
  }

  private async execute(job: ProxyDelayJob): Promise<void> {
    let delay: number | undefined;
    try {
      const runtime = await readRuntime(job.filesDir);
      if (runtime === undefined || job.cancelled) {
        return;
      }
      const request = http.createHttp();
      job.request = request;
      const header: Record<string, string> = { 'Authorization': `Bearer ${runtime.secret}` };
      const path = `/arkclash/delay?profile=${encodeURIComponent(job.target.profile)}` +
        `&id=${encodeURIComponent(job.target.id)}&url=${encodeURIComponent(job.target.url)}` +
        `&group=${encodeURIComponent(job.target.group)}&expectedBootId=${encodeURIComponent(job.target.expectedBootId)}` +
        `&expectedRevision=${job.target.expectedRevision}&timeout=${PROXY_TEST_TIMEOUT}`;
      const response = await request.request(`http://${CONTROLLER_ADDRESS}${path}`, {
        method: http.RequestMethod.GET, header: header, connectTimeout: 3000,
        readTimeout: PROXY_TEST_TIMEOUT + 2000, expectDataType: http.HttpDataType.STRING
      });
      delay = proxyDelayResponse(response.responseCode, response.result as string);
    } catch (e) {
      // controller 断连、客户端取消或请求未被受理都不是节点失败。
    } finally {
      job.request?.destroy();
      job.request = undefined;
      this.active--;
      if (!job.cancelled) {
        if (this.jobs.get(job.target.key) === job) {
          this.jobs.delete(job.target.key);
        }
        const update: ProxyDelayUpdate = {
          key: job.target.key, phase: 'idle', delay: delay, noConclusion: delay === undefined
        };
        job.batches.forEach((batch: ProxyDelayBatch): void => {
          if (!batch.cancelled) {
            batch.onUpdate(update);
            batch.pending.delete(job.target.key);
            if (batch.pending.size === 0) {
              this.finishBatch(batch);
            }
          }
        });
      }
      this.pump();
    }
  }

  private finishBatch(batch: ProxyDelayBatch): void {
    this.batches.delete(batch.id);
    if (!batch.cancelled) {
      batch.onFinish();
    }
  }
}

const proxyDelayScheduler: ProxyDelayScheduler = new ProxyDelayScheduler();

export function testProxyDelays(filesDir: string, owner: string, targets: ProxyDelayTarget[],
  onUpdate: (update: ProxyDelayUpdate) => void, onFinish: () => void): ProxyDelayBatch {
  return proxyDelayScheduler.start(filesDir, owner, targets, onUpdate, onFinish);
}

export function cancelProxyDelayOwner(owner: string): void {
  proxyDelayScheduler.cancelOwner(owner);
}
