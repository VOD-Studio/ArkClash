import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection as networkConnection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OutboundMode, RuntimeStatus, setAllowLan, setMode } from './Controller';
import { ControllerSocket } from './ControllerSocket';
import {
  CoreHostState, connectVpn, disconnectVpn, hostInterrupted, readCoreHostStatus, startCore, stopCore,
  updateRuntimeOptions
} from './CoreClient';
import { backgroundKeep } from './BackgroundKeep';
import { flushProxySelections } from './Proxies';
import { traffic } from './Traffic';
import { vpnHostBinding } from './VpnHostBinding';
import { runtimeMayBeActive } from '../shared/Runtime';
import { flushGeoSettings } from '../shared/GeoResources';

const PREF_CONNECT_DURATION = 'lastConnectDuration';
const PREF_MODE = 'outboundMode';
const PREF_ALLOW_LAN = 'allowLan';
// 宿主退出后的恢复间隔。内存不足时刚拉起的宿主可能再次被回收，按次数逐步拉长，
// 30 分钟内最多恢复 4 次，之后等用户回到前台（ADR-0037）。
const RECOVERY_DELAYS_MS: number[] = [2000, 15000, 60000, 300000];
const RECOVERY_WINDOW_MS = 30 * 60 * 1000;
// 系统登记进程退出需要一点时间，宿主状态未确认前不改写 runtime。
const HOST_EXIT_CHECKS = 10;
const HOST_EXIT_CHECK_MS = 300;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

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
  @Trace panelOpen: boolean = false;
  @Trace sessionMode: 'tun' | 'proxyOnly' = 'tun';
  @Trace listenersOpen: boolean = false;
  @Trace tunAttached: boolean = false;
  @Trace vpnCreated: boolean = false;
  @Trace coreReady: boolean = false;
  @Trace coreStarting: boolean = false;
  private automaticFailed: boolean = false;
  private resumeVpn: boolean = false;
  private context?: common.UIAbilityContext;
  // 用户希望保持连接：连接时置位，断开时清除。宿主退出后据此决定是否恢复。
  private wantConnected: boolean = false;
  private recovering: boolean = false;
  private recoveryTimes: number[] = [];
  private readyPending?: Promise<void>;
  @Trace modePending: boolean = false;
  @Trace modeError: string = '';
  @Trace routeRevision: string = '';
  private coreGeneration: number = 0;
  @Trace hostState: CoreHostState = 'unknown';
  private prefs?: preferences.Preferences;
  private filesDir: string = '';
  private generation: number = 0;
  private modeGeneration: number = 0;
  private startPending?: Promise<void>;
  private settingsPending: Promise<void> = Promise.resolve();
  private foreground: boolean = false;
  private diagnosticsReceiverMounted: boolean = false;
  private diagnosticsCapture?: ControllerSocket;
  private diagnosticsBootId: string = '';
  @Trace bootId: string = '';
  @Trace configRevision: number = 0;
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
    return this.coreReady && this.state === ConnectionState.Connected && this.forward === 'running' &&
      this.vpnCreated && this.tunAttached && this.listenersOpen;
  }

  get offlineWritable(): boolean {
    return this.hostState === 'stopped' && !this.busy;
  }

  restore(context: common.UIAbilityContext): void {
    this.context = context;
    vpnHostBinding.setListener((bootId: string): void => { this.hostLost(bootId); });
    backgroundKeep.restore(context);
    this.filesDir = context.filesDir;
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    const saved = this.prefs.getSync(PREF_MODE, '') as string;
    this.mode = saved === 'rule' || saved === 'global' || saved === 'direct' ? saved : '';
    this.connectDuration = this.prefs.getSync(PREF_CONNECT_DURATION, 0) as number;
    this.allowLan = this.prefs.hasSync(PREF_ALLOW_LAN) ? this.prefs.getSync(PREF_ALLOW_LAN, false) as boolean : undefined;
    // 历史连接标记不能证明当前隧道存在；首帧只恢复用户偏好。
  }

  setDiagnosticsReceiverMounted(mounted: boolean): void {
    this.diagnosticsReceiverMounted = mounted;
    this.syncDiagnosticsCapture();
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
      backgroundKeep.foreground();
    } else {
      const observer = this.network;
      this.network = undefined;
      if (observer !== undefined && this.networkRegistered) {
        observer.unregister((): void => {});
      }
      this.networkRegistered = false;
    }
  }

  async ensureReady(context: common.UIAbilityContext, automatic: boolean = false): Promise<void> {
    if (automatic && (!this.foreground || this.automaticFailed)) {
      return;
    }
    if (this.readyPending !== undefined) {
      return this.readyPending;
    }
    const generation = this.coreGeneration;
    this.coreStarting = true;
    const pending = this.prepareCore(context, generation, automatic);
    this.readyPending = pending;
    try {
      await pending;
    } catch (error) {
      if (automatic) {
        this.automaticFailed = true;
      }
      throw error as Error;
    } finally {
      if (this.readyPending === pending) {
        this.readyPending = undefined;
        this.coreStarting = false;
      }
    }
    this.resumeInterrupted(context);
  }

  // 系统只在后台回收 VPN 进程，不会自己重新拉起；回到前台、内核就绪后恢复一次，失败后等用户手动连接。
  private resumeInterrupted(context: common.UIAbilityContext): void {
    if (!this.resumeVpn) {
      return;
    }
    this.resumeVpn = false;
    if (!this.foreground || this.busy || this.connected || !this.coreReady || this.hostState !== 'running') {
      return;
    }
    hilog.info(0x0A11, 'ArkClashBench', 'vpn_resume_interrupted');
    const generation = this.generation + 1;
    this.connect(context).catch((): void => {
      // 常见原因是系统里已有其他 VPN（2203002）。不提示错误，界面保持断开。
      if (generation === this.generation && !this.busy) {
        this.error = '';
      }
    });
  }

  // 后台是否允许恢复。界面进程在后台会被冻结，只有持有长时任务时回调才能及时执行。
  private backgroundRecovery(): boolean {
    return backgroundKeep.running;
  }

  // 用户希望保持连接时由后台保持持有长时任务，宿主恢复期间不释放。
  private setWantConnected(wanted: boolean): void {
    this.wantConnected = wanted;
    backgroundKeep.sync(wanted);
  }

  // 绑定断开即宿主进程已退出（ADR-0038）。用户希望保持连接时立即恢复，不必等回到前台。
  private hostLost(bootId: string): void {
    const context = this.context;
    if (context === undefined || bootId !== this.bootId) {
      return;
    }
    hilog.info(0x0A11, 'ArkClashBench', 'vpn_host_lost');
    if (!this.foreground && !this.backgroundRecovery()) {
      return;
    }
    if (!this.wantConnected) {
      if (this.foreground) {
        this.recheck(context).catch((): void => {});
      }
      return;
    }
    this.recoverHost(context).catch((): void => {});
  }

  private async recoverHost(context: common.UIAbilityContext): Promise<void> {
    if (this.recovering) {
      return;
    }
    const now = Date.now();
    this.recoveryTimes = this.recoveryTimes.filter((at: number): boolean => now - at < RECOVERY_WINDOW_MS);
    if (this.recoveryTimes.length >= RECOVERY_DELAYS_MS.length) {
      hilog.info(0x0A11, 'ArkClashBench', 'vpn_recover_limited');
      return;
    }
    const delay = Math.max(RECOVERY_DELAYS_MS[this.recoveryTimes.length], backgroundKeep.pressureDelayMs());
    this.recoveryTimes.push(now);
    this.recovering = true;
    const generation = this.generation;
    const current = (): boolean => generation === this.generation && this.wantConnected &&
      (this.foreground || this.backgroundRecovery());
    let attempt = -1;
    try {
      await sleep(delay);
      let host = await readCoreHostStatus(context);
      for (let i = 0; i < HOST_EXIT_CHECKS && host.state === 'unknown' && current(); ++i) {
        await sleep(HOST_EXIT_CHECK_MS);
        host = await readCoreHostStatus(context);
      }
      if (!current() || this.busy) {
        return;
      }
      if (host.state === 'running' && host.status !== undefined) {
        // 其他路径已经拉起了新宿主。
        this.applyStatus(host.status);
        if (this.connected) {
          return;
        }
      } else if (host.state !== 'stopped') {
        return;
      } else {
        const interrupted = await hostInterrupted(context.filesDir);
        if (!current() || this.busy) {
          return;
        }
        if (!interrupted) {
          // 留下了停止回执：用户在系统设置里断开，或被其他 VPN 接管。
          this.setWantConnected(false);
          this.applyStopped();
          return;
        }
        this.applyStopped();
      }
      hilog.info(0x0A11, 'ArkClashBench', 'vpn_recover_start');
      await this.ensureReady(context);
      if (!current() || this.busy || this.connected) {
        return;
      }
      attempt = this.generation + 1;
      await this.connect(context);
      if (this.connected) {
        hilog.info(0x0A11, 'ArkClashBench', 'vpn_recover_done');
      }
    } catch (_error) {
      hilog.info(0x0A11, 'ArkClashBench', 'vpn_recover_failed');
      if (attempt === this.generation && !this.busy) {
        // 与回前台恢复一致：失败时不提示，用户手动连接时照常显示原因。
        this.error = '';
      }
    } finally {
      this.recovering = false;
    }
  }

  private async prepareCore(context: common.UIAbilityContext, generation: number, automatic: boolean): Promise<void> {
    try {
      await this.settingsPending;
      await flushGeoSettings();
      await flushProxySelections(this.filesDir);
      if (generation !== this.coreGeneration || (automatic && !this.foreground)) {
        return;
      }
      const start = await startCore(context, this.userMode(), this.allowLan,
        (): boolean => generation === this.coreGeneration && (!automatic || this.foreground));
      if (generation === this.coreGeneration) {
        this.applyStatus(start.status);
        this.resumeVpn = start.resumeVpn;
      }
    } catch (error) {
      if (generation === this.coreGeneration) {
        const host = await readCoreHostStatus(context);
        if (generation === this.coreGeneration) {
          if (host.state === 'stopped') {
            this.applyStopped();
          } else if (host.status !== undefined) {
            this.applyStatus(host.status);
          } else {
            this.markUnknown((error as Error).message);
          }
          this.error = (error as Error).message;
        }
      }
      throw error as Error;
    }
  }
  async connect(context: common.UIAbilityContext): Promise<void> {
    if (this.busy || this.connected) {
      return;
    }
    if (this.readyPending !== undefined) {
      const waitingGeneration = this.generation;
      await this.readyPending.catch((): void => {});
      if (waitingGeneration !== this.generation || this.busy || this.connected) {
        return;
      }
    }
    const generation = ++this.generation;
    this.setWantConnected(true);
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
      await this.ensureReady(context);
      if (generation !== this.generation) {
        return;
      }
      this.state = ConnectionState.Connecting;
      this.intent = 'started';
      this.forward = 'preparing';
      this.events.stop();
      const host = await readCoreHostStatus(context);
      if (host.status === undefined || host.state !== 'running') {
        throw new Error('内核未就绪，请重试');
      }
      const status = await connectVpn(context, host.status,
        (): boolean => generation === this.generation);
      if (generation !== this.generation) {
        return;
      }
      if (status.tunAttached && status.vpnCreated && status.forward === 'running') {
        hilog.info(0x0A11, 'ArkClashBench', 'vpn_tun_confirmed');
      }
      this.applyStatus(status);
      this.connectDuration = Math.max(0, Date.now() - begin);
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      const host = await readCoreHostStatus(context).catch((): undefined => undefined);
      if (generation !== this.generation) {
        return;
      }
      if (host?.state === 'running' && host.status !== undefined) {
        this.applyStatus(host.status);
      } else if (host?.state === 'stopped') {
        this.applyStopped();
      } else {
        this.markUnknown((error as Error).message);
      }
      this.error = (error as Error).message;
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
    const generation = ++this.generation;
    this.setWantConnected(false);
    this.intent = 'stopped';
    this.error = '';
    this.state = ConnectionState.Disconnecting;
    this.events.stop();
    const pending = this.startPending;
    let failure: Error | undefined = undefined;
    try {
      await this.readyPending?.catch((): void => {});
      const host = await readCoreHostStatus(context);
      if (host.state === 'running' && host.status !== undefined) {
        const status = await disconnectVpn(context, host.status,
          (): boolean => generation === this.generation);
        if (generation === this.generation) {
          this.applyStatus(status);
        }
      } else if (host.state === 'unknown') {
        ++this.coreGeneration;
        await stopCore(context);
      }
    } catch (error) {
      failure = error as Error;
    }
    // 取消期间系统可能晚于第一次 stop 才创建扩展，必须等启动代次收尾后重新取证。
    await pending?.catch((): void => {});
    const host = await readCoreHostStatus(context).catch((): undefined => undefined);
    if (generation !== this.generation) {
      return;
    }
    if (failure === undefined && host?.state === 'running' && host.status !== undefined &&
      host.status.forward === 'stopped' && !host.status.vpnCreated &&
      !host.status.tunAttached && !host.status.listenersOpen) {
      this.applyStatus(host.status);
      return;
    }
    if (host?.state === 'stopped') {
      this.applyStopped();
      return;
    }
    const error = failure ?? new Error('尚未确认代理已停止，请重试');
    if (host?.state === 'running' && host.status !== undefined) {
      this.applyStatus(host.status);
      this.error = error.message;
    } else {
      this.markUnknown(error.message);
    }
    throw error;
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
    this.coreReady = false;
    this.state = ConnectionState.Disconnected;
    this.forward = 'failed';
    this.error = message;
    this.invalidateRoute();
    this.syncEvents();
  }

  private applyStopped(): void {
    this.hostState = 'stopped';
    this.coreReady = false;
    this.state = ConnectionState.Disconnected;
    this.intent = 'stopped';
    this.forward = 'stopped';
    this.connectedAt = 0;
    this.configRevision = 0;
    this.listenersOpen = false;
    this.tunAttached = false;
    this.vpnCreated = false;
    this.error = '';
    traffic.reset();
    this.invalidateRoute();
    this.syncEvents();
    this.syncDiagnosticsCapture();
  }

  private applyStatus(status: RuntimeStatus): void {
    if (status.bootId === this.bootId && status.revision < this.revision) {
      return;
    }
    this.bootId = status.bootId;
    this.revision = status.revision;
    this.configRevision = status.configRevision;
    this.coreVersion = status.version;
    this.hostState = status.running ? 'running' : 'stopped';
    this.coreReady = status.running;
    this.vpnCreated = status.vpnCreated;
    this.intent = status.intent;
    this.forward = status.forward;
    this.sessionMode = status.sessionMode;
    this.panelOpen = status.panelOpen === true;
    this.listenersOpen = status.listenersOpen;
    this.tunAttached = status.tunAttached;
    this.connectedAt = status.startedAt;
    if (status.mode === 'rule' || status.mode === 'global' || status.mode === 'direct') {
      this.mode = status.mode;
    }
    this.state = status.running && status.forward === 'running' && status.vpnCreated &&
      status.tunAttached && status.listenersOpen ? ConnectionState.Connected : ConnectionState.Disconnected;
    this.routeRevision = `${this.bootId}/${this.revision}/${this.routeEpoch}`;
    if (status.running && !this.busy && !this.recovering) {
      this.setWantConnected(status.intent === 'started');
    }
    if (status.running && this.context !== undefined) {
      vpnHostBinding.bind(this.context, status.bootId);
    }
    this.syncEvents();
    this.syncDiagnosticsCapture();
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
    if (this.foreground && !this.busy && this.coreReady) {
      this.events.start(this.filesDir);
    } else {
      this.events.stop();
    }
  }

  private syncDiagnosticsCapture(): void {
    if (!this.diagnosticsReceiverMounted || this.hostState === 'stopped' ||
      this.diagnosticsBootId !== this.bootId) {
      this.diagnosticsCapture?.stop();
      this.diagnosticsCapture = undefined;
      this.diagnosticsBootId = '';
    }
    // 失去状态查询不代表内核或已有租约已失效；只凭认证状态开始订阅。
    if (!this.diagnosticsReceiverMounted || !this.coreReady || this.hostState !== 'running' || this.bootId === '') {
      return;
    }
    if (this.diagnosticsCapture === undefined) {
      const path = `/arkclash/diagnostics/capture?expectedBootId=${encodeURIComponent(this.bootId)}`;
      this.diagnosticsCapture = new ControllerSocket(path, (): void => {}, undefined, 'ready');
      this.diagnosticsBootId = this.bootId;
    }
    this.diagnosticsCapture.start(this.filesDir);
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
