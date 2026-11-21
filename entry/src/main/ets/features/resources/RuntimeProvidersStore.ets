import { common } from '@kit.AbilityKit';
import { ControllerSocket } from '../../client/ControllerSocket';
import {
  getRuntimeProviders, parseRuntimeProvidersEvent, replaceRuntimeProviderFromUri, RuntimeProviderItem,
  RuntimeProviderKind, RuntimeProviderOutcome, RuntimeProviderPhase, RuntimeProvidersSnapshot,
  RuntimeProviderVehicle, runtimeProviderError, runtimeProviderKey, updateRuntimeProvider
} from '../../client/RuntimeProviders';

@ObservedV2
export class RuntimeProviderRowModel implements RuntimeProviderItem {
  @Trace kind: RuntimeProviderKind;
  @Trace name: string;
  @Trace vehicleType: RuntimeProviderVehicle;
  @Trace count: number;
  @Trace updatedAt: number;
  @Trace behavior: string;
  @Trace format: string;
  @Trace updatable: boolean;
  @Trace replaceable: boolean;
  @Trace phase: RuntimeProviderPhase;
  @Trace outcome: RuntimeProviderOutcome;
  @Trace error: string;

  constructor(item: RuntimeProviderItem) {
    this.kind = item.kind;
    this.name = item.name;
    this.vehicleType = item.vehicleType;
    this.count = item.count;
    this.updatedAt = item.updatedAt;
    this.behavior = item.behavior ?? '';
    this.format = item.format ?? '';
    this.updatable = item.updatable;
    this.replaceable = item.replaceable;
    this.phase = item.phase;
    this.outcome = item.outcome;
    this.error = item.error;
  }

  get key(): string {
    return runtimeProviderKey(this.kind, this.name);
  }

  updateFrom(item: RuntimeProviderItem): void {
    this.vehicleType = item.vehicleType;
    this.count = item.count;
    this.updatedAt = item.updatedAt;
    this.behavior = item.behavior ?? '';
    this.format = item.format ?? '';
    this.updatable = item.updatable;
    this.replaceable = item.replaceable;
    this.phase = item.phase;
    this.outcome = item.outcome;
    this.error = item.error;
  }
}

export interface RuntimeProviderNotice {
  kind: 'updated' | 'unchanged' | 'replaced' | 'error';
  providerKind: RuntimeProviderKind;
  name: string;
  error: string;
}

export function providerErrorText(code: string): Resource {
  switch (code) {
    case 'provider_unavailable': return $r('app.string.provider_err_unavailable');
    case 'provider_stale_config': return $r('app.string.provider_err_stale_config');
    case 'provider_not_found': return $r('app.string.provider_err_not_found');
    case 'provider_not_updatable': return $r('app.string.provider_err_not_updatable');
    case 'provider_not_replaceable': return $r('app.string.provider_err_not_replaceable');
    case 'provider_busy': return $r('app.string.provider_err_busy');
    case 'provider_invalid_content': return $r('app.string.provider_err_invalid_content');
    case 'provider_timeout': return $r('app.string.provider_err_timeout');
    case 'provider_io': return $r('app.string.provider_err_io');
    default: return $r('app.string.provider_err_update_failed');
  }
}

@ObservedV2
export class RuntimeProvidersStore {
  @Trace proxyItems: RuntimeProviderRowModel[] = [];
  @Trace ruleItems: RuntimeProviderRowModel[] = [];
  @Trace loaded: boolean = false;
  @Trace ready: boolean = false;
  @Trace connected: boolean = false;
  @Trace error: string = '';
  @Trace noticeSerial: number = 0;
  @Trace notice?: RuntimeProviderNotice;
  private visible: boolean = false;
  private bootId: string = '';
  private configRevision: number = 0;
  private snapshotRevision: number = -1;
  private filesDir: string = '';
  private generation: number = 0;
  private socket?: ControllerSocket;
  private pendingKeys: Set<string> = new Set<string>();
  private rowsByKey: Map<string, RuntimeProviderRowModel> = new Map<string, RuntimeProviderRowModel>();

  get hasProviders(): boolean {
    return this.proxyItems.length > 0 || this.ruleItems.length > 0;
  }

  get canRefreshRemote(): boolean {
    return this.visible && this.ready && this.connected && this.bootId !== '' && this.configRevision > 0;
  }

  get canReplaceLocal(): boolean {
    return this.visible && this.ready && this.bootId !== '' && this.configRevision > 0;
  }

  isBusy(kind: RuntimeProviderKind, name: string): boolean {
    const key = runtimeProviderKey(kind, name);
    if (this.pendingKeys.has(key)) {
      return true;
    }
    const row = this.rowsByKey.get(key);
    return row !== undefined && row.phase === 'updating';
  }

  load(context: common.UIAbilityContext): void {
    this.filesDir = context.filesDir;
    this.syncSession();
  }

  setVisible(visible: boolean): void {
    if (this.visible === visible) {
      return;
    }
    this.visible = visible;
    if (!visible) {
      this.stopSession(false);
      this.clearNotice();
    } else {
      this.syncSession();
    }
  }

  setConnection(coreReady: boolean, connected: boolean, bootId: string, configRevision: number): void {
    const identityChanged = this.ready !== coreReady || this.bootId !== bootId ||
      this.configRevision !== configRevision;
    this.ready = coreReady;
    this.connected = connected;
    this.bootId = bootId;
    this.configRevision = configRevision;
    if (!identityChanged) {
      return;
    }
    this.stopSession(!coreReady || bootId === '');
    if (this.visible) {
      this.syncSession();
    }
  }

  clearNotice(): void {
    this.notice = undefined;
  }

  private emitNotice(notice: RuntimeProviderNotice): void {
    if (!this.visible) {
      return;
    }
    this.notice = notice;
    this.noticeSerial++;
  }

  private stopSession(clearItems: boolean): void {
    this.generation++;
    this.socket?.stop();
    this.socket = undefined;
    this.snapshotRevision = -1;
    this.pendingKeys.clear();
    if (clearItems) {
      this.loaded = false;
      this.error = '';
      this.proxyItems = [];
      this.ruleItems = [];
      this.rowsByKey.clear();
    }
  }

  private syncSession(): void {
    if (!this.visible || !this.ready || this.bootId === '' || this.configRevision <= 0 || this.filesDir === '') {
      this.stopSession(!this.ready || this.bootId === '');
      return;
    }
    if (this.socket !== undefined && this.socket.active) {
      return;
    }
    const generation = ++this.generation;
    const expectedBootId = this.bootId;
    const expectedConfigRev = this.configRevision;
    this.error = '';
    this.fetchInitial(generation, expectedBootId, expectedConfigRev);
    const socket = new ControllerSocket('/arkclash/providers/events', (text: string): void => {
      if (generation !== this.generation) {
        return;
      }
      try {
        const snapshot = parseRuntimeProvidersEvent(text);
        this.applySnapshot(snapshot, generation);
      } catch (_error) {
        socket.fail('provider_invalid_content');
      }
    });
    this.socket = socket;
    socket.start(this.filesDir);
  }

  private async fetchInitial(generation: number, expectedBootId: string, expectedConfigRev: number): Promise<void> {
    try {
      const snapshot = await getRuntimeProviders(this.filesDir);
      if (generation !== this.generation || this.bootId !== expectedBootId ||
        this.configRevision !== expectedConfigRev) {
        return;
      }
      this.applySnapshot(snapshot, generation);
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      this.loaded = true;
      this.error = runtimeProviderError(error as Object);
    }
  }

  applySnapshot(snapshot: RuntimeProvidersSnapshot, generation: number): void {
    if (generation !== this.generation || snapshot.bootId !== this.bootId ||
      snapshot.configRevision !== this.configRevision) {
      return;
    }
    if (snapshot.revision < this.snapshotRevision) {
      return;
    }
    this.snapshotRevision = snapshot.revision;
    this.loaded = true;
    this.error = '';
    const nextProxies: RuntimeProviderRowModel[] = [];
    const nextRules: RuntimeProviderRowModel[] = [];
    const nextMap = new Map<string, RuntimeProviderRowModel>();
    for (const item of snapshot.items) {
      const key = runtimeProviderKey(item.kind, item.name);
      const existing = this.rowsByKey.get(key);
      let row: RuntimeProviderRowModel;
      if (existing !== undefined) {
        existing.updateFrom(item);
        row = existing;
      } else {
        row = new RuntimeProviderRowModel(item);
      }
      if (this.pendingKeys.has(key) && row.phase === 'idle') {
        row.phase = 'updating';
      }
      nextMap.set(key, row);
      if (item.kind === 'proxy') {
        nextProxies.push(row);
      } else {
        nextRules.push(row);
      }
    }
    this.rowsByKey = nextMap;
    this.proxyItems = nextProxies;
    this.ruleItems = nextRules;
  }

  async refreshProvider(kind: RuntimeProviderKind, name: string): Promise<void> {
    if (!this.canRefreshRemote) {
      return;
    }
    const key = runtimeProviderKey(kind, name);
    if (this.isBusy(kind, name)) {
      return;
    }
    const generation = this.generation;
    const bootId = this.bootId;
    const configRevision = this.configRevision;
    this.pendingKeys.add(key);
    const row = this.rowsByKey.get(key);
    if (row !== undefined) {
      row.phase = 'updating';
      row.error = '';
    }
    try {
      const snapshot = await updateRuntimeProvider(this.filesDir, bootId, configRevision, kind, name);
      if (generation !== this.generation || bootId !== this.bootId || configRevision !== this.configRevision) {
        return;
      }
      this.pendingKeys.delete(key);
      this.applySnapshot(snapshot, generation);
      const updated = this.rowsByKey.get(key);
      this.emitNotice({
        kind: updated?.outcome === 'unchanged' ? 'unchanged' : 'updated',
        providerKind: kind,
        name: name,
        error: ''
      });
    } catch (error) {
      if (generation !== this.generation || bootId !== this.bootId || configRevision !== this.configRevision) {
        return;
      }
      this.pendingKeys.delete(key);
      const code = runtimeProviderError(error as Object);
      const current = this.rowsByKey.get(key);
      if (current !== undefined) {
        current.phase = 'idle';
        if (code !== 'provider_stale_config') {
          current.outcome = 'failed';
          current.error = code;
        }
      }
      this.emitNotice({ kind: 'error', providerKind: kind, name: name, error: code });
    }
  }

  async replaceProvider(kind: RuntimeProviderKind, name: string, uri: string): Promise<void> {
    if (!this.canReplaceLocal || uri === '') {
      return;
    }
    const key = runtimeProviderKey(kind, name);
    if (this.isBusy(kind, name)) {
      return;
    }
    const generation = this.generation;
    const bootId = this.bootId;
    const configRevision = this.configRevision;
    this.pendingKeys.add(key);
    const row = this.rowsByKey.get(key);
    if (row !== undefined) {
      row.phase = 'updating';
      row.error = '';
    }
    try {
      const snapshot = await replaceRuntimeProviderFromUri(this.filesDir, bootId, configRevision, kind, name, uri);
      if (generation !== this.generation || bootId !== this.bootId || configRevision !== this.configRevision) {
        return;
      }
      this.pendingKeys.delete(key);
      this.applySnapshot(snapshot, generation);
      const updated = this.rowsByKey.get(key);
      this.emitNotice({
        kind: updated?.outcome === 'unchanged' ? 'unchanged' : 'replaced',
        providerKind: kind,
        name: name,
        error: ''
      });
    } catch (error) {
      if (generation !== this.generation || bootId !== this.bootId || configRevision !== this.configRevision) {
        return;
      }
      this.pendingKeys.delete(key);
      const code = runtimeProviderError(error as Object);
      const current = this.rowsByKey.get(key);
      if (current !== undefined) {
        current.phase = 'idle';
        if (code !== 'provider_stale_config') {
          current.outcome = 'failed';
          current.error = code;
        }
      }
      this.emitNotice({ kind: 'error', providerKind: kind, name: name, error: code });
    }
  }
}
