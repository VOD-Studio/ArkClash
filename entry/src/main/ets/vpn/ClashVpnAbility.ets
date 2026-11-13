// VPN 扩展持有内核与 TUN；系统销毁扩展后不承诺继续运行。
import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import core from 'libarkclash.so';
import { hasFile } from '../shared/Files';
import { newId, ProfileRecord, readList, yamlPath } from '../shared/profiles/Store';
import { UpdateEnv, UpdateScheduler } from '../shared/profiles/Updater';
import { beginRuntimeInstance, CONTROLLER_ADDRESS, readRuntime, writeCoreError, writeRuntimeStopped } from '../shared/Runtime';
import { installGeoData } from './GeoData';
import { KernelDownloader } from './KernelDownloader';
import { emitUpdated, serveProfileCommands } from './ProfileCommands';

const DOMAIN = 0x0A11;
const TAG = 'ClashVpnAbility';

// Must match tunAddress in core/tun.go.
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
// Any address routed into the TUN works; mihomo hijacks all port-53 traffic.
const TUN_DNS = '172.19.0.2';
const TUN_MTU = 1500;
const FAMILY_IPV4 = 1;
// 连接稳定后再在后台补齐其他配置的 rule-provider，不和连接本身抢资源。
const PREFETCH_DELAY_MS = 10000;

// 和 core/lib.go 的 startOptions 一致。
interface CoreOptions {
  homeDir: string;
  configPath: string;
  tunFd: number;
  controller: string;
  secret: string;
  stack: string;
  profile: string;
  mode: string;
  allowLan?: boolean;
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  // 连接期间订阅由这个进程更新（#35），断开时停掉，进行中的更新不再提交。
  private scheduler?: UpdateScheduler;
  private prefetchTimer: number = -1;
  private stopped: boolean = false;
  private generation: number = 1;
  private startup?: Promise<void>;
  private cleanupPending?: Promise<void>;
  private coreTouched: boolean = false;
  private runtimeSecret: string = '';
  private runtimeInstance: string = newId('vpn.');

  onCreate(_want: Want): void {
    const generation = this.generation;
    this.startup = this.start(generation);
    this.startup.catch((error: Error): void => {
      if (!this.stopped) {
        hilog.error(DOMAIN, TAG, 'start failed');
        writeCoreError(this.context.filesDir, error.message);
      }
      this.stopped = true;
      ++this.generation;
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
    this.stopped = true;
    ++this.generation;
    clearTimeout(this.prefetchTimer);
    this.scheduler?.stop(true);
    this.cleanup().catch((): void => {
      hilog.error(DOMAIN, TAG, 'resource cleanup incomplete');
    });
  }

  private checkGeneration(generation: number): void {
    if (this.stopped || generation !== this.generation) {
      throw new Error('启动已取消');
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
    clearTimeout(this.prefetchTimer);
    this.scheduler?.stop(true);
    let failure: Error | undefined = undefined;
    if (this.coreTouched) {
      try {
        const stopped: Promise<void> = core.stop();
        await stopped;
        this.coreTouched = false;
      } catch (error) {
        failure = error as Error;
      }
    }
    const connection = this.connection;
    if (connection !== undefined) {
      try {
        await connection.destroy();
        this.connection = undefined;
      } catch (error) {
        failure = failure ?? error as Error;
      }
    }
    if (failure !== undefined) {
      throw failure;
    }
    if (this.runtimeSecret !== '') {
      await writeRuntimeStopped(this.context.filesDir, this.runtimeSecret, this.runtimeInstance);
    }
  }

  private async start(generation: number): Promise<void> {
    const filesDir = this.context.filesDir;
    const runtime = await readRuntime(filesDir);
    if (runtime === undefined) {
      throw new Error('runtime.json missing, start the VPN from the app');
    }
    this.runtimeSecret = runtime.secret;
    await beginRuntimeInstance(filesDir, this.runtimeSecret, this.runtimeInstance);
    this.checkGeneration(generation);
    // 用哪份配置以列表为准，系统直接拉起扩展进程时也能用上最新的选择（ADR-0010）。
    const profile = readList(filesDir).current;
    if (profile === '' || !hasFile(yamlPath(filesDir, profile))) {
      throw new Error('no profile selected, add one in the app');
    }
    await installGeoData(this.context, filesDir);
    this.checkGeneration(generation);

    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    // ArkTS/libc 的出站用进程保护；Go 的 socket 在 core/socket.go 单独绑定物理网络。
    await connection.protectProcessNet();
    this.checkGeneration(generation);

    const config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: TUN_ADDRESS, family: FAMILY_IPV4 },
        prefixLength: TUN_PREFIX
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: { address: { address: '0.0.0.0', family: FAMILY_IPV4 }, prefixLength: 0 },
        gateway: { address: TUN_ADDRESS, family: FAMILY_IPV4 },
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: [TUN_DNS],
      mtu: TUN_MTU,
      // 界面进程保持直连；出口与服务探测经 controller 交给内核按当前规则拨号。
      blockedApplications: [this.context.applicationInfo.name]
    };
    const tunFd = await connection.create(config);
    this.checkGeneration(generation);
    hilog.info(DOMAIN, TAG, 'tun created, fd=%{public}d', tunFd);

    const options: CoreOptions = {
      homeDir: filesDir,
      configPath: yamlPath(filesDir, profile),
      tunFd: tunFd,
      controller: CONTROLLER_ADDRESS,
      secret: runtime.secret,
      stack: runtime.stack,
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
        const reloaded: Promise<void> = core.reload(path, id, expectedProfile);
        return reloaded;
      },
      prefetch: (path: string) => {
        this.prefetch(path).catch(() => {});
      }
    };
    const scheduler = new UpdateScheduler(env, emitUpdated);
    this.scheduler = scheduler;
    serveProfileCommands(scheduler, env);
    this.checkGeneration(generation);
    this.coreTouched = true;
    const started: Promise<void> = core.start(JSON.stringify(options));
    await started;
    this.checkGeneration(generation);
    hilog.info(DOMAIN, TAG, 'core started');
    scheduler.start();
    this.prefetchTimer = setTimeout(() => {
      this.prefetchOthers(filesDir).catch(() => {});
    }, PREFETCH_DELAY_MS);
  }

  private async prefetch(path: string): Promise<void> {
    const pending: Promise<string> = core.prefetch(path);
    hilog.info(DOMAIN, TAG, 'prefetch: %{public}s', await pending);
  }

  // 未连接时添加的订阅没机会预下载，连接后逐个补上；本地已有的文件内核会跳过。
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
