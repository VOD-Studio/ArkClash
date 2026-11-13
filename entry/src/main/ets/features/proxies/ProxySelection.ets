import {
  matchesProxySelectionIdentity, observeProxySelections, proxyMemberNode, proxySelectionIdentity,
  ProxySelectionChange, ProxySelectionCommand, ProxySelectionResult,
  ProxyNodeSnapshot, ProxySnapshot, submitProxySelection
} from '../../client/Proxies';
import { newId } from '../../shared/profiles/Store';
import { proxySelectionIntent, selectableProxyGroup } from './ProxyLogic';
import { ProxyPendingSelection } from './ProxyView';

export class ProxySelectionSession {
  readonly pending: Map<string, ProxyPendingSelection> = new Map<string, ProxyPendingSelection>();
  private stopObserving?: () => void;
  private snapshotProvider?: () => ProxySnapshot | undefined;
  private onChange: () => void;
  private onNotice: (notice: string) => void;
  private onReload: () => void;

  constructor(onChange: () => void, onNotice: (notice: string) => void, onReload: () => void) {
    this.onChange = onChange;
    this.onNotice = onNotice;
    this.onReload = onReload;
  }

  observe(current: () => ProxySnapshot | undefined): void {
    this.unobserve();
    this.snapshotProvider = current;
    this.stopObserving = observeProxySelections((change: ProxySelectionChange): void => {
      const snapshot = current();
      if (snapshot !== undefined) {
        this.apply(snapshot, change);
      } else {
        this.onReload();
      }
    });
  }

  unobserve(): void {
    this.stopObserving?.();
    this.stopObserving = undefined;
  }

  clear(): void {
    this.pending.clear();
  }

  choose(filesDir: string, snapshot: ProxySnapshot, groupName: string, nodeName: string,
    closeConnections: boolean, stillCurrent: () => boolean): void {
    if (!snapshot.online && !snapshot.offlineWritable) {
      this.onNotice('hostUnknown');
      return;
    }
    const group = snapshot.nodes[groupName];
    if (group === undefined || !selectableProxyGroup(group.type)) {
      this.onNotice('unsupported');
      return;
    }
    const node = proxyMemberNode(snapshot, groupName, nodeName);
    if (!group.members.includes(nodeName) || node === undefined || node.missing) {
      this.onNotice('unresolved');
      return;
    }
    if (!node.selectable) {
      this.onNotice('notAddressable');
      return;
    }
    const previous = this.pending.get(groupName);
    const saved = snapshot.selected[groupName] ?? '';
    const current = previous !== undefined ? previous.clearPin ? '' :
      proxyMemberNode(snapshot, groupName, previous.target)?.name ?? '' : group.type === 'Selector' ? group.now : saved;
    const intent = proxySelectionIntent(group.type, current, node.name);
    if (!intent.changed) {
      return;
    }
    this.commit(filesDir, snapshot, group, node.id, intent.name, intent.clearPin, closeConnections, stillCurrent);
  }

  clearPin(filesDir: string, snapshot: ProxySnapshot, groupName: string,
    closeConnections: boolean, stillCurrent: () => boolean): void {
    if (!snapshot.online && !snapshot.offlineWritable) {
      this.onNotice('hostUnknown');
      return;
    }
    const group = snapshot.nodes[groupName];
    if (group === undefined || !['URLTest', 'Fallback'].includes(group.type)) {
      this.onNotice('unsupported');
      return;
    }
    if ((snapshot.selected[groupName] ?? '') === '' && !this.pending.has(groupName)) {
      return;
    }
    this.commit(filesDir, snapshot, group, '', '', true, closeConnections, stillCurrent);
  }

  private commit(filesDir: string, snapshot: ProxySnapshot, group: ProxyNodeSnapshot, nodeId: string,
    name: string, clearPin: boolean, closeConnections: boolean, stillCurrent: () => boolean): void {
    const groupName = group.name;
    const identity = proxySelectionIdentity(snapshot);
    const command: ProxySelectionCommand = {
      profile: snapshot.profile, group: groupName, name: name, nodeId: nodeId,
      clearPin: clearPin, closeConnections: closeConnections, operationId: newId('selection.'),
      expectedBootId: snapshot.bootId, expectedRevision: snapshot.configRevision
    };
    this.pending.set(groupName, {
      operationId: command.operationId, target: nodeId, clearPin: clearPin
    });
    this.onChange();
    submitProxySelection(filesDir, command, group, identity, stillCurrent)
      .then((result: ProxySelectionResult): void => {
        if (!stillCurrent()) {
          if (this.pending.get(groupName)?.operationId === command.operationId) {
            this.pending.delete(groupName);
          }
          this.onReload();
          return;
        }
        const current = this.snapshotProvider === undefined ? snapshot : this.snapshotProvider();
        if (current === undefined || !matchesProxySelectionIdentity(current, identity)) {
          this.onReload();
          return;
        }
        if (this.pending.get(groupName)?.operationId === command.operationId) {
          this.apply(current, { command: command, result: result, identity: identity });
        }
        this.onReload();
      }).catch((error: Error): void => {
        if (!stillCurrent()) {
          if (this.pending.get(groupName)?.operationId === command.operationId) {
            this.pending.delete(groupName);
            this.onChange();
          }
          this.onReload();
          return;
        }
        if (this.pending.get(groupName)?.operationId !== command.operationId) {
          return;
        }
        this.pending.delete(groupName);
        this.onNotice(error.message.includes('selection_inconsistent') ? 'inconsistent' : 'selectionFailed');
        this.onChange();
        this.onReload();
      });
  }

  private apply(snapshot: ProxySnapshot, change: ProxySelectionChange): void {
    if (!matchesProxySelectionIdentity(snapshot, change.identity)) {
      this.onReload();
      return;
    }
    const command = change.command;
    const pending = this.pending.get(command.group);
    if (pending !== undefined && pending.operationId !== command.operationId) {
      return;
    }
    const group = snapshot.nodes[command.group];
    const actual = proxyMemberNode(snapshot, command.group, change.result.selectedId);
    if (group === undefined ||
      (change.result.selectedId !== '' && actual?.name !== change.result.selected) ||
      (change.result.pinned !== '' && !group.members.some((id: string): boolean =>
        proxyMemberNode(snapshot, group.name, id)?.name === change.result.pinned))) {
      this.onReload();
      return;
    }
    snapshot.selected[command.group] = group.type === 'Selector' ? change.result.selected : change.result.pinned;
    group.now = change.result.selected;
    group.nowId = change.result.selectedId;
    if (actual !== undefined) {
      snapshot.actualNodes[command.group] = actual;
    } else if (snapshot.actualNodes[command.group] !== undefined) {
      const retained: Record<string, ProxyNodeSnapshot> = {};
      for (const name of Object.keys(snapshot.actualNodes)) {
        if (name !== command.group) { retained[name] = snapshot.actualNodes[name]; }
      }
      snapshot.actualNodes = retained;
    }
    this.pending.delete(command.group);
    this.onChange();
    if (change.result.cleanupFailed) {
      this.onNotice('cleanupFailed');
    }
  }
}
