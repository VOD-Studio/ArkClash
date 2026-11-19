// VPN 扩展持有内核与 TUN；系统销毁扩展后不承诺继续运行。
import { refreshDueScripts } from './ScriptUpdates';
import { Want } from '@kit.AbilityKit';
import { connection as networkConnection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import core from 'libarkclash.so';
import { hasFile } from '../shared/Files';
import { newId, ProfileRecord, readList, readListAsync, validProfileId, withProfileStorage,
  yamlPath } from '../shared/profiles/Store';
import { UpdateEnv, UpdateScheduler } from '../shared/profiles/Updater';
import { beginRuntimeInstance, CONTROLLER_ADDRESS, readRuntime, RuntimeConfig, writeCoreError,
  writeRuntime, writeRuntimeStopped } from '../shared/Runtime';
import {
  TUN_IPV4, TUN_IPV4_DNS, TUN_IPV6, TUN_IPV6_DNS, vpnExcludedApplications, VpnNetworkSettings, VpnRoutePrefix, vpnRoutePrefixes
} from '../shared/VpnNetwork';
import { serveCommands, VpnCommandError } from './Commands';
import { installGeoData } from './GeoData';
import { KernelDownloader } from './KernelDownloader';
import { emitUpdated } from './ProfileCommands';

const DOMAIN = 0x0A11;
const TAG = 'ClashVpnAbility';

const FAMILY_IPV4 = 1;
const FAMILY_IPV6 = 2;
// 内核就绪后再补齐其他配置的 rule-provider，不和启动抢资源。
const PREFETCH_DELAY_MS = 10000;

// 和 core/lifecycle.go 的 startOptions 一致。
interface CoreOptions {
  homeDir: string;
  configPath: string;
  controller: string;
  secret: string;
  profile: string;
  mode: string;
  allowLan?: boolean;
}

interface VpnOperationRequest {
  bootId: string;
  operationId: string;
  profile?: string;
  configRevision?: number;
}

interface VpnNativeStatus {
  running: boolean;
  bootId: string;
  profile: string;
  configRevision: number;
  intent: string;
  forward: string;
  tunAttached: boolean;
  listenersOpen: boolean;
  vpnCreated: boolean;
}

interface VpnQueuedOperation {
  name: string;
  request: VpnOperationRequest;
  generation: number;
  pending?: Promise<Object>;
}

interface VpnCleanupResult {
  errors: string[];
  canceled?: VpnCommandError;
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private scheduler?: UpdateScheduler;
  private prefetchTimer: number = -1;
  private stopped: boolean = false;
  private generation: number = 1;
  private startup?: Promise<void>;
  private cleanupPending?: Promise<void>;
  private operationQueue: Promise<void> = Promise.resolve();
  private latestOperation?: VpnQueuedOperation;
  private coreTouched: boolean = false;
  private nativeInitialized: boolean = false;
  private vpnCreated: boolean = false;
  // create 拒绝也必须尝试 destroy，不能把没有 fd 当作平台已释放的证据。
  private platformNeedsCleanup: boolean = false;
  private runtimeSecret: string = '';
  private runtimeInstance: string = newId('vpn.');
  private bootId: string = '';

  onCreate(_want: Want): void {
    const generation = this.generation;
    this.startup = this.start(generation);
    this.startup.catch((error: Error): void => {
      if (this.stopped) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'start failed');
      writeCoreError(this.context.filesDir, error.message);
      this.invalidateHost();
      this.cleanup().then(async (): Promise<void> => {
        await vpnExtension.stopVpnExtensionAbility({
          bundleName: this.context.applicationInfo.name, abilityName: 'ClashVpnAbility'
        });
      }).catch((): void => {
        hilog.error(DOMAIN, TAG, 'startup cleanup failed');
      });
    });
  }

  onDestroy(): void {
    this.invalidateHost();
    this.cleanup().catch((): void => {
      hilog.error(DOMAIN, TAG, 'resource cleanup incomplete');
    });
  }

  private invalidateHost(): void {
    this.stopped = true;
    ++this.generation;
    clearTimeout(this.prefetchTimer);
    this.scheduler?.stop(true);
  }

  private checkGeneration(generation: number): void {
    if (this.stopped || generation !== this.generation) {
      throw new VpnCommandError(409, 'canceled');
    }
  }

  private cleanup(): Promise<void> {
    if (this.cleanupPending === undefined) {
      const pending = this.releaseResources();
      this.cleanupPending = pending;
      pending.catch((): void => {
        if (this.cleanupPending === pending) {
          this.cleanupPending = undefined;
        }
      });
    }
    return this.cleanupPending;
  }

  private async releaseResources(): Promise<void> {
    await this.startup?.catch((): void => {});
    await this.operationQueue;
    clearTimeout(this.prefetchTimer);
    this.scheduler?.stop(true);
    const result = await this.cleanupForwarding(undefined, true);
    if (this.coreTouched) {
      try {
        const stopping: Promise<void> = core.stop();
        await stopping;
        this.coreTouched = false;
      } catch (_error) {
        result.errors.push('core_stop_failed');
      }
    }
    if (this.nativeInitialized) {
      try {
        const status = await this.nativeStatus();
        if (status.running || status.tunAttached || status.listenersOpen || status.vpnCreated) {
          result.errors.push('vpn_cleanup_incomplete');
        }
      } catch (_error) {
        result.errors.push('vpn_state_failed');
      }
    }
    if (this.vpnCreated || this.platformNeedsCleanup) {
      result.errors.push('vpn_cleanup_incomplete');
    }
    if (result.errors.length !== 0) {
      throw new VpnCommandError(500, result.errors.join(';'));
    }
    this.connection = undefined;
    if (this.runtimeSecret !== '') {
      await writeRuntimeStopped(this.context.filesDir, this.runtimeSecret, this.runtimeInstance);
    }
  }

  private async start(generation: number): Promise<void> {
    const filesDir = this.context.filesDir;
    const runtime = await withProfileStorage<RuntimeConfig>(filesDir, async (): Promise<RuntimeConfig> => {
      const saved = await readRuntime(filesDir);
      this.checkGeneration(generation);
      if (saved === undefined || typeof saved.secret !== 'string' || saved.secret === '') {
        throw new Error('runtime.json missing, start the core from the app');
      }
      this.runtimeSecret = saved.secret;
      await beginRuntimeInstance(filesDir, this.runtimeSecret, this.runtimeInstance);
      this.checkGeneration(generation);
      saved.vpnIntent = 'stopped';
      saved.vpnOperation = newId('vpn.');
      await writeRuntime(filesDir, saved);
      this.checkGeneration(generation);
      return saved;
    });
    this.checkGeneration(generation);
    // 用哪份配置以列表为准，空选择只预热内核；损坏的已选配置不能降级为空配置。
    const profile = (await readListAsync(filesDir)).current;
    this.checkGeneration(generation);
    if (profile !== '' && !hasFile(yamlPath(filesDir, profile))) {
      throw new Error('selected profile is missing');
    }
    await installGeoData(this.context, filesDir);
    this.checkGeneration(generation);

    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    // ArkTS/libc 的出站用进程保护；Go 的 socket 在 core/socket.go 单独绑定物理网络。
    await connection.protectProcessNet();
    this.checkGeneration(generation);

    const options: CoreOptions = {
      homeDir: filesDir,
      configPath: profile === '' ? '' : yamlPath(filesDir, profile),
      controller: CONTROLLER_ADDRESS,
      secret: runtime.secret,
      profile: profile,
      mode: runtime.mode,
      allowLan: runtime.allowLan
    };
    const env: UpdateEnv = {
      filesDir: filesDir,
      eligible: (): boolean => !this.stopped && generation === this.generation,
      downloader: new KernelDownloader(),
      running: () => core.runningProfile(),
      reload: (path: string, id: string, expectedProfile?: string): Promise<void> => {
        return core.reload(path, id, expectedProfile);
      },
      updateResources: (eligible: () => boolean): Promise<void> => refreshDueScripts(filesDir, eligible),
      prefetch: (path: string) => {
        this.prefetch(path).catch(() => {});
      }
    };
    const scheduler = new UpdateScheduler(env, emitUpdated);
    this.scheduler = scheduler;
    serveCommands(scheduler, env, (name: string, body: string): Promise<Object> => {
      return this.handleVpnCommand(name, body);
    });
    this.checkGeneration(generation);
    this.coreTouched = true;
    this.nativeInitialized = true;
    const starting: Promise<void> = core.start(JSON.stringify(options));
    await starting;
    this.checkGeneration(generation);
    const status = await this.nativeStatus();
    this.checkGeneration(generation);
    if (!status.running || status.bootId === '' || status.tunAttached || status.listenersOpen || status.vpnCreated) {
      throw new Error('core warmup failed');
    }
    this.bootId = status.bootId;
    hilog.info(DOMAIN, TAG, 'core started without VPN');
    scheduler.start();
    this.prefetchTimer = setTimeout(() => {
      this.prefetchOthers(filesDir).catch(() => {});
    }, PREFETCH_DELAY_MS);
  }

  private nativeStatus(): Promise<VpnNativeStatus> {
    return core.runtimeStatus().then((body: string): VpnNativeStatus => JSON.parse(body) as VpnNativeStatus);
  }

  private async checkRequest(request: VpnOperationRequest, name: string,
    generation: number): Promise<RuntimeConfig> {
    this.checkGeneration(generation);
    let runtime: RuntimeConfig | undefined = undefined;
    try {
      runtime = await readRuntime(this.context.filesDir);
    } catch (_error) {
      this.checkGeneration(generation);
      throw new VpnCommandError(409, 'conflict');
    }
    this.checkGeneration(generation);
    if (runtime === undefined || runtime.secret !== this.runtimeSecret || request.bootId !== this.bootId ||
      runtime.vpnOperation !== request.operationId || runtime.vpnIntent !== (name === 'connect' ? 'started' : 'stopped')) {
      throw new VpnCommandError(409, 'conflict');
    }
    return runtime;
  }

  private async checkOperation(operation: VpnQueuedOperation): Promise<RuntimeConfig> {
    if (this.latestOperation !== operation) {
      throw new VpnCommandError(409, 'conflict');
    }
    const runtime = await this.checkRequest(operation.request, operation.name, operation.generation);
    if (this.latestOperation !== operation) {
      throw new VpnCommandError(409, 'conflict');
    }
    return runtime;
  }

  private async handleVpnCommand(name: string, body: string): Promise<Object> {
    if (name !== 'connect' && name !== 'disconnect') {
      throw new VpnCommandError(400, 'unsupported_input');
    }
    const request = JSON.parse(body) as VpnOperationRequest;
    if (typeof request.bootId !== 'string' || request.bootId === '' ||
      typeof request.operationId !== 'string' || request.operationId === '' ||
      name === 'connect' && (typeof request.profile !== 'string' || !validProfileId(request.profile) ||
        typeof request.configRevision !== 'number' || !Number.isSafeInteger(request.configRevision) ||
        request.configRevision <= 0)) {
      throw new VpnCommandError(400, 'unsupported_input');
    }
    const generation = this.generation;
    await this.startup;
    await this.checkRequest(request, name, generation);
    const previous = this.latestOperation;
    if (previous !== undefined && previous.request.operationId === request.operationId) {
      if (previous.name !== name || previous.request.bootId !== request.bootId ||
        previous.request.profile !== request.profile || previous.request.configRevision !== request.configRevision) {
        throw new VpnCommandError(409, 'conflict');
      }
      const pending = previous.pending;
      if (pending !== undefined) {
        return pending;
      }
    }
    const operation: VpnQueuedOperation = { name: name, request: request, generation: generation };
    // 接受新意图就作废旧 connect；清理仍留在同一队列，不能销毁下一次连接。
    this.latestOperation = operation;
    const pending: Promise<Object> = this.operationQueue.then((): Promise<Object> => {
      return name === 'connect' ? this.connect(operation) : this.disconnect(operation);
    });
    operation.pending = pending;
    this.operationQueue = pending.then((): void => {}, (): void => {});
    return pending;
  }

  private async connect(operation: VpnQueuedOperation): Promise<Object> {
    await this.checkOperation(operation);
    const status = await this.nativeStatus();
    const runtime = await this.checkOperation(operation);
    const request = operation.request;
    if (!status.running || status.bootId !== request.bootId || status.profile !== request.profile ||
      status.configRevision !== request.configRevision || status.profile === '') {
      throw new VpnCommandError(409, 'conflict');
    }
    if (status.forward === 'running' && status.intent === 'started' && status.tunAttached && status.vpnCreated) {
      return status;
    }
    if (status.tunAttached || status.listenersOpen || status.vpnCreated || this.platformNeedsCleanup) {
      throw new VpnCommandError(409, 'conflict');
    }
    const connection = this.connection;
    if (connection === undefined) {
      throw new VpnCommandError(409, 'canceled');
    }
    let phase = 'vpn_state_failed';
    try {
      const preparing: Promise<void> = core.updateVpnState('started', 'preparing', false);
      await preparing;
      await this.checkOperation(operation);
      const defaults = new VpnNetworkSettings();
      defaults.stack = runtime.stack || defaults.stack;
      const network = runtime.network ?? defaults;
      const config = this.vpnConfig(network);
      phase = 'vpn_create_failed';
      this.platformNeedsCleanup = true;
      const tunFd = await connection.create(config);
      this.vpnCreated = true;
      await this.checkOperation(operation);
      phase = 'vpn_state_failed';
      const registered: Promise<void> = core.updateVpnState('started', 'preparing', true);
      await registered;
      await this.checkOperation(operation);
      phase = 'vpn_attach_failed';
      const attaching: Promise<void> = core.attachTun(tunFd, JSON.stringify(network), request.bootId, request.profile ?? '',
        request.configRevision ?? 0);
      await attaching;
      await this.checkOperation(operation);
      phase = 'vpn_state_failed';
      const forwarding: Promise<void> = core.updateVpnState('started', 'running', true);
      await forwarding;
      await this.checkOperation(operation);
      const ready = await this.nativeStatus();
      await this.checkOperation(operation);
      if (!ready.running || ready.forward !== 'running' || !ready.tunAttached || !ready.vpnCreated) {
        throw new VpnCommandError(500, 'vpn_state_failed');
      }
      return ready;
    } catch (error) {
      const message = (error as Error).message;
      const nativeConflict = phase === 'vpn_attach_failed' &&
        (message === 'conflict' || message === 'stale_attach_identity');
      const failure = error instanceof VpnCommandError ? error :
        new VpnCommandError(nativeConflict ? 409 : 500, nativeConflict ? 'conflict' : phase);
      const cleanup = await this.cleanupForwarding(operation);
      if (cleanup.errors.length !== 0) {
        throw new VpnCommandError(500, `${failure.message};${cleanup.errors.join(';')}`);
      }
      throw cleanup.canceled ?? failure;
    }
  }

  private vpnConfig(network: VpnNetworkSettings): vpnExtension.VpnConfig {
    const ownBundle = this.context.applicationInfo.name;
    const config: vpnExtension.VpnConfig = {
      // 地址、前缀长度和 DNS 地址须与 core/tun.go 一致。
      addresses: [{ address: { address: TUN_IPV4, family: FAMILY_IPV4 }, prefixLength: 30 }],
      routes: vpnRoutePrefixes(network).map((route: VpnRoutePrefix): networkConnection.RouteInfo => {
        const family = route.ipv6 ? FAMILY_IPV6 : FAMILY_IPV4;
        return {
          interface: 'vpn-tun',
          destination: { address: { address: route.address, family: family }, prefixLength: route.length },
          gateway: { address: route.ipv6 ? TUN_IPV6 : TUN_IPV4, family: family },
          hasGateway: false,
          isDefaultRoute: route.length === 0
        };
      }),
      dnsAddresses: [TUN_IPV4_DNS],
      isIPv6Accepted: network.ipv6,
      mtu: network.mtu,
      // 界面进程保持直连；出口与服务探测经 controller 交给内核按当前规则拨号。
      blockedApplications: [ownBundle].concat(vpnExcludedApplications(network.excludedApplications, ownBundle))
    };
    if (network.ipv6) {
      config.addresses.push({ address: { address: TUN_IPV6, family: FAMILY_IPV6 }, prefixLength: 126 });
      config.dnsAddresses?.push(TUN_IPV6_DNS);
    }
    return config;
  }

  private async disconnect(operation: VpnQueuedOperation): Promise<Object> {
    await this.checkOperation(operation);
    const status = await this.nativeStatus();
    await this.checkOperation(operation);
    if (!status.running || status.bootId !== operation.request.bootId) {
      throw new VpnCommandError(409, 'conflict');
    }
    if (status.intent === 'stopped' && status.forward === 'stopped' && !status.tunAttached && !status.listenersOpen &&
      !status.vpnCreated && !this.platformNeedsCleanup) {
      return status;
    }
    const result = await this.cleanupForwarding(operation);
    if (result.errors.length !== 0) {
      throw new VpnCommandError(500, result.errors.join(';'));
    }
    if (result.canceled !== undefined) {
      throw result.canceled;
    }
    const stopped = await this.nativeStatus();
    await this.checkOperation(operation);
    return stopped;
  }

  private async observeCleanup(operation: VpnQueuedOperation | undefined, result: VpnCleanupResult): Promise<void> {
    if (operation !== undefined) {
      try {
        await this.checkOperation(operation);
      } catch (error) {
        result.canceled = error as VpnCommandError;
      }
    }
  }

  private async cleanupForwarding(operation?: VpnQueuedOperation, forceStopped: boolean = false): Promise<VpnCleanupResult> {
    const result: VpnCleanupResult = { errors: [] };
    if (this.coreTouched) {
      try {
        const detaching: Promise<void> = core.detachTun();
        await detaching;
      } catch (_error) {
        result.errors.push('vpn_detach_failed');
      }
      await this.observeCleanup(operation, result);
    }
    const connection = this.connection;
    if (connection !== undefined && (this.vpnCreated || this.platformNeedsCleanup)) {
      try {
        await connection.destroy();
        this.vpnCreated = false;
        this.platformNeedsCleanup = false;
      } catch (_error) {
        result.errors.push('vpn_destroy_failed');
      }
      await this.observeCleanup(operation, result);
    }
    if (this.nativeInitialized) {
      let intent = 'stopped';
      if (!forceStopped && !this.stopped) {
        try {
          const runtime = await readRuntime(this.context.filesDir);
          if (runtime?.secret === this.runtimeSecret && runtime.vpnIntent === 'started') {
            intent = 'started';
          }
        } catch (_error) {
          result.canceled = new VpnCommandError(409, 'conflict');
        }
        await this.observeCleanup(operation, result);
      }
      try {
        const published: Promise<void> = core.updateVpnState(intent, result.errors.length === 0 ? 'stopped' : 'failed',
          this.vpnCreated);
        await published;
      } catch (_error) {
        result.errors.push('vpn_state_failed');
      }
      await this.observeCleanup(operation, result);
    }
    return result;
  }

  private async prefetch(path: string): Promise<void> {
    const pending: Promise<string> = core.prefetch(path);
    hilog.info(DOMAIN, TAG, 'prefetch: %{public}s', await pending);
  }

  private async prefetchOthers(filesDir: string): Promise<void> {
    const running = core.runningProfile();
    for (const record of readList(filesDir).profiles.filter((p: ProfileRecord) => p.id !== running)) {
      if (this.stopped) {
        return;
      }
      await this.prefetch(yamlPath(filesDir, record.id));
    }
  }
}
