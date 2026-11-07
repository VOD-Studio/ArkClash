// Hosts the mihomo core. Runs in its own process, which the system keeps alive
// while the VPN is up, independent of the UI.
import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import core from 'libarkclash.so';
import { hasFile } from '../shared/Files';
import { ProfileRecord, readList, yamlPath } from '../shared/profiles/Store';
import { UpdateEnv, UpdateScheduler } from '../shared/profiles/Updater';
import { CONTROLLER_ADDRESS, readRuntime, writeCoreError } from '../shared/Runtime';
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

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.start().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', e.message);
      writeCoreError(this.context.filesDir, e.message);
      this.connection?.destroy();
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.stopped = true;
    clearTimeout(this.prefetchTimer);
    this.scheduler?.stop(true);
    core.stop();
    this.connection?.destroy();
  }

  private async start(): Promise<void> {
    const filesDir = this.context.filesDir;
    const runtime = readRuntime(filesDir);
    if (runtime === undefined) {
      throw new Error('runtime.json missing, start the VPN from the app');
    }
    // 用哪份配置以列表为准，系统直接拉起扩展进程时也能用上最新的选择（ADR-0010）。
    const profile = readList(filesDir).current;
    if (profile === '' || !hasFile(yamlPath(filesDir, profile))) {
      throw new Error('no profile selected, add one in the app');
    }

    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    // ArkTS/libc 的出站用进程保护；Go 的 socket 在 core/socket.go 单独绑定物理网络。
    await connection.protectProcessNet();

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
      // 界面进程保持直连；查询代理出口等功能显式使用内核的 HTTP 代理端口。
      blockedApplications: [this.context.applicationInfo.name]
    };
    const tunFd = await connection.create(config);
    hilog.info(DOMAIN, TAG, 'tun created, fd=%{public}d', tunFd);

    const geoCopied = await installGeoData(this.context, filesDir);
    hilog.info(DOMAIN, TAG, 'geo data copied: %{public}d', geoCopied);

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
    // 先赋给带类型的变量再 await：codelinter 解析不到 .so 的类型声明，直接 await 会误报 await-thenable。
    const started: Promise<void> = core.start(JSON.stringify(options));
    await started;
    hilog.info(DOMAIN, TAG, 'core %{public}s started', core.version());

    const env: UpdateEnv = {
      filesDir: filesDir,
      downloader: new KernelDownloader(),
      running: () => core.runningProfile(),
      reload: (path: string, id: string): Promise<void> => {
        const reloaded: Promise<void> = core.reload(path, id);
        return reloaded;
      },
      prefetch: (path: string) => {
        this.prefetch(path).catch(() => {});
      }
    };
    const scheduler = new UpdateScheduler(env, emitUpdated);
    this.scheduler = scheduler;
    serveProfileCommands(scheduler, env);
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
