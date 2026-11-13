import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection as networkConnection } from '@kit.NetworkKit';
import { OutboundMode, RuntimeStatus, setAllowLan, setMode } from './Controller';
import { ControllerSocket } from './ControllerSocket';
import { CoreHostState, CoreStartError, probeCore, readCoreHostStatus, startCore, stopCore, updateRuntimeOptions } from './CoreClient';
import { flushProxySelections } from './Proxies';
import { traffic } from './Traffic';
import { runtimeMayBeActive } from '../shared/Runtime';

const PREF_CONNECT_DURATION = 'lastConnectDuration';
const PREF_MODE = 'outboundMode';
const PREF_ALLOW_LAN = 'allowLan';

export enum ConnectionState {
  Disconnected,
  Connecting,
  Connected,
  Disconnecting
}

interface RuntimeEvent {
  type: string;
  status?: RuntimeStatus;
}

@ObservedV2
export class Connection {
  @Trace state: ConnectionState = ConnectionState.Disconnected;
  @Trace coreVersion: string = '';
  @Trace error: string = '';
  @Trace connectedAt: number = 0;
  @Trace connectDuration: number = 0;
  @Trace mode: OutboundMode | '' = '';
  @Trace allowLan: boolean | undefined = undefined;
  @Trace intent: 'started' | 'stopped' = 'stopped';
  @Trace forward: 'stopped' | 'preparing' | 'running' | 'paused' | 'failed' = 'stopped';
  @Trace sessionMode: 'tun' | 'proxyOnly' = 'tun';
  @Trace listenersOpen: boolean = false;
  @Trace tunAttached: boolean = false;
  @Trace modePending: boolean = false;
  @Trace modeError: string = '';
  @Trace routeRevision: string = '';
  @Trace hostState: CoreHostState = 'unknown';
  private prefs?: preferences.Preferences;
  private filesDir: string = '';
  private generation: number = 0;
  private modeGeneration: number = 0;
  private startPending?: Promise<void>;
  private settingsPending: Promise<void> = Promise.resolve();
  private foreground: boolean = false;
  @Trace bootId: string = '';
  private revision: number = -1;
  private routeEpoch: number = 0;
  private network?: networkConnection.NetConnection;
  private networkRegistered: boolean = false;
  private events: ControllerSocket = new ControllerSocket('/arkclash/events', (text: string): void => {
    try {
      const event = JSON.parse(text) as RuntimeEvent;
      if (event.type === 'runtime' && event.status !== undefined && !this.busy) {
        this.receiveStatus(event.status).catch((): void => { this.invalidateRoute(); });
      }
    } catch (_error) {
      this.invalidateRoute();
    }
  });

  get busy(): boolean {
    return this.state === ConnectionState.Connecting || this.state === ConnectionState.Disconnecting;
  }

  get connected(): boolean {
    return this.state === ConnectionState.Connected && this.forward === 'running' &&
      (this.sessionMode === 'tun' ? this.tunAttached : this.listenersOpen);
  }

  get offlineWritable(): boolean {
    return this.hostState === 'stopped' && !this.busy;
  }

  restore(context: common.UIAbilityContext): void {
    this.filesDir = context.filesDir;
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    const saved = this.prefs.getSync(PREF_MODE, '') as string;
    this.mode = saved === 'rule' || saved === 'global' || saved === 'direct' ? saved : '';
    this.connectDuration = this.prefs.getSync(PREF_CONNECT_DURATION, 0) as number;
    this.allowLan = this.prefs.hasSync(PREF_ALLOW_LAN) ? this.prefs.getSync(PREF_ALLOW_LAN, false) as boolean : undefined;
    // 历史连接标记不能证明当前隧道存在；首帧只恢复用户偏好。
  }

  observe(context: common.UIAbilityContext, visible: boolean): void {
    if (this.foreground === visible) {
      this.syncEvents();
      return;
    }
    this.foreground = visible;
    this.syncEvents();
    if (visible) {
      this.invalidateRoute();
      this.watchNetwork();
      this.recheck(context).catch((): void => {});
    } else {
      const observer = this.network;
      this.network = undefined;
      if (observer !== undefined && this.networkRegistered) {
        observer.unregister((): void => {});
      }
      this.networkRegistered = false;
    }
  }

  async connect(context: common.UIAbilityContext): Promise<void> {
    if (this.busy || this.connected) {
      return;
    }
    const generation = ++this.generation;
    this.intent = 'started';
    this.error = '';
    this.forward = 'preparing';
    this.state = ConnectionState.Connecting;
    this.events.stop();
    const begin = Date.now();
    const pending = this.performConnect(context, generation, begin);
    this.startPending = pending;
    try {
      await pending;
    } finally {
      if (this.startPending === pending) {
        this.startPending = undefined;
      }
    }
  }

  private async performConnect(context: common.UIAbilityContext, generation: number, begin: number): Promise<void> {
    try {
      const host = await readCoreHostStatus(context);
      if (generation !== this.generation) {
        return;
      }
      if (host.state === 'unknown') {
        throw new CoreStartError('尚未确认代理状态，请重试', true);
      }
      if (host.state === 'running' && host.status !== undefined) {
        this.applyStatus(host.status);
        return;
      }
      this.hostState = 'stopped';
      await this.settingsPending.catch((): void => {});
      await flushProxySelections(this.filesDir);
      if (generation !== this.generation) {
        return;
      }
      this.hostState = 'unknown';
      const status = await startCore(context, this.userMode(), this.allowLan,
        (): boolean => generation === this.generation && this.intent === 'started');
      if (generation !== this.generation) {
        return;
      }
      this.applyStatus(status);
      this.connectDuration = Math.max(0, Date.now() - begin);
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      if (error instanceof CoreStartError && !error.extensionStarted) {
        this.hostState = 'stopped';
      }
      if (this.hostState === 'stopped') {
        this.applyStopped();
        this.forward = 'failed';
        this.error = (error as Error).message;
      } else {
        this.markUnknown((error as Error).message);
      }
      throw error as Error;
    }
    try {
      this.prefs?.putSync(PREF_CONNECT_DURATION, this.connectDuration);
      await this.prefs?.flush();
    } catch (_error) {
      this.error = '代理已连接，但连接耗时未能保存';
    }
  }

  async disconnect(context: common.UIAbilityContext): Promise<void> {
    if (this.state === ConnectionState.Disconnecting) {
      throw new Error('代理正在停止，请稍后重试');
    }
    ++this.generation;
    this.intent = 'stopped';
    this.error = '';
    this.state = ConnectionState.Disconnecting;
    this.hostState = 'unknown';
    this.events.stop();
    const pending = this.startPending;
    try {
      await stopCore(context);
      await pending?.catch((): void => {});
      this.applyStopped();
    } catch (error) {
      this.error = (error as Error).message;
      let status: RuntimeStatus | undefined = undefined;
      try {
        status = await probeCore(context);
      } catch (_error) {
        status = undefined;
      }
      if (status !== undefined && status.running) {
        this.applyStatus(status);
      } else {
        this.markUnknown((error as Error).message);
      }
      throw error as Error;
    }
  }

  async recheck(context: common.UIAbilityContext): Promise<boolean> {
    if (this.busy) {
      throw new Error('代理状态正在切换，请稍后重试');
    }
    const generation = this.generation;
    try {
      const host = await readCoreHostStatus(context);
      if (generation !== this.generation || this.busy) {
        throw new Error('代理状态已变化，请重试');
      }
      if (host.state === 'unknown') {
        throw new Error('尚未确认代理状态，请重试');
      }
      if (host.state === 'running' && host.status !== undefined) {
        this.applyStatus(host.status);
      } else {
        this.applyStopped();
      }
      return this.hostState === 'running';
    } catch (error) {
      if (generation === this.generation && !this.busy) {
        this.markUnknown((error as Error).message);
      }
      throw error as Error;
    }
  }

  private async receiveStatus(status: RuntimeStatus): Promise<void> {
    const generation = this.generation;
    let unconfirmed = false;
    try {
      unconfirmed = !status.running && await runtimeMayBeActive(this.filesDir);
    } catch (_error) {
      unconfirmed = true;
    }
    if (generation !== this.generation || this.busy) {
      return;
    }
    if (unconfirmed) {
      this.markUnknown('尚未确认代理状态，请重试');
    } else if (status.running) {
      this.applyStatus(status);
    } else {
      this.applyStopped();
    }
  }

  private markUnknown(message: string): void {
    this.hostState = 'unknown';
    this.state = ConnectionState.Disconnected;
    this.forward = 'failed';
    this.intent = 'started';
    this.error = message;
    this.invalidateRoute();
    this.syncEvents();
  }

  private applyStopped(): void {
    this.hostState = 'stopped';
    this.state = ConnectionState.Disconnected;
    this.intent = 'stopped';
    this.forward = 'stopped';
    this.connectedAt = 0;
    this.listenersOpen = false;
    this.tunAttached = false;
    this.error = '';
    traffic.reset();
    this.invalidateRoute();
    this.syncEvents();
  }

  private applyStatus(status: RuntimeStatus): void {
    if (status.bootId === this.bootId && status.revision < this.revision) {
      return;
    }
    this.bootId = status.bootId;
    this.revision = status.revision;
    this.coreVersion = status.version;
    this.hostState = status.running ? 'running' : 'stopped';
    this.intent = status.intent;
    this.forward = status.forward;
    this.sessionMode = status.sessionMode;
    this.listenersOpen = status.listenersOpen;
    this.tunAttached = status.tunAttached;
    this.connectedAt = status.startedAt;
    if (status.mode === 'rule' || status.mode === 'global' || status.mode === 'direct') {
      this.mode = status.mode;
    }
    this.state = status.running && status.forward === 'running' &&
      (status.sessionMode === 'tun' ? status.tunAttached : status.listenersOpen) ?
      ConnectionState.Connected : ConnectionState.Disconnected;
    this.routeRevision = `${this.bootId}/${this.revision}/${this.routeEpoch}`;
    this.syncEvents();
  }

  private userMode(): string {
    return (this.prefs?.getSync(PREF_MODE, '') as string | undefined) ?? '';
  }

  private requireKnownHost(): void {
    if (this.hostState === 'unknown') {
      throw new Error('尚未确认代理状态，请重试');
    }
  }

  async changeMode(mode: OutboundMode): Promise<void> {
    if (mode === this.mode && !this.modePending) {
      return;
    }
    const generation = ++this.modeGeneration;
    this.modePending = true;
    this.modeError = '';
    const work = this.settingsPending.catch((): void => {}).then(async (): Promise<void> => {
      this.requireKnownHost();
      this.prefs?.putSync(PREF_MODE, mode);
      await this.prefs?.flush();
      this.requireKnownHost();
      if (this.hostState === 'running') {
        await updateRuntimeOptions(this.filesDir, mode, this.allowLan);
        await setMode(this.filesDir, mode);
      }
      if (generation === this.modeGeneration) {
        this.mode = mode;
        this.invalidateRoute();
      }
    });
    this.settingsPending = work;
    try {
      await work;
    } catch (error) {
      if (generation === this.modeGeneration) {
        this.modeError = '出站模式未能应用，请重试';
        this.error = this.modeError;
      }
      throw error as Error;
    } finally {
      if (generation === this.modeGeneration) {
        this.modePending = false;
      }
    }
  }

  async changeAllowLan(allow: boolean): Promise<void> {
    const work = this.settingsPending.catch((): void => {}).then(async (): Promise<void> => {
      this.requireKnownHost();
      this.prefs?.putSync(PREF_ALLOW_LAN, allow);
      await this.prefs?.flush();
      this.requireKnownHost();
      if (this.hostState === 'running') {
        await updateRuntimeOptions(this.filesDir, this.userMode(), allow);
        await setAllowLan(this.filesDir, allow);
      }
      this.allowLan = allow;
    });
    this.settingsPending = work;
    try {
      await work;
    } catch (error) {
      this.error = '局域网代理设置未能应用，请重试';
      throw error as Error;
    }
  }

  private syncEvents(): void {
    if (this.foreground && !this.busy && this.hostState !== 'stopped' && this.intent === 'started') {
      this.events.start(this.filesDir);
    } else {
      this.events.stop();
    }
  }

  private invalidateRoute(): void {
    ++this.routeEpoch;
    this.routeRevision = `${this.bootId}/${this.revision}/${this.routeEpoch}`;
  }

  private watchNetwork(): void {
    if (this.network !== undefined) {
      return;
    }
    const observer = networkConnection.createNetConnection();
    this.network = observer;
    const changed = (): void => {
      if (this.foreground && this.network === observer) {
        this.invalidateRoute();
      }
    };
    observer.on('netAvailable', changed);
    observer.on('netLost', changed);
    observer.on('netCapabilitiesChange', changed);
    observer.register((error: BusinessError): void => {
      if (error) {
        if (this.network === observer) {
          this.network = undefined;
        }
        return;
      }
      if (this.network !== observer || !this.foreground) {
        observer.unregister((): void => {});
      } else {
        this.networkRegistered = true;
      }
    });
  }
}

export const connection: Connection = new Connection();
