// Hosts the mihomo core. Runs in its own process, which the system keeps alive
// while the VPN is up, independent of the UI.
import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import core from 'libarkclash.so';
import { CONTROLLER_ADDRESS, readRuntime, writeCoreError } from '../common/Runtime';

const DOMAIN = 0x0A11;
const TAG = 'ClashVpnAbility';

// Must match tunAddress in core/tun.go.
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
// Any address routed into the TUN works; mihomo hijacks all port-53 traffic.
const TUN_DNS = '172.19.0.2';
const TUN_MTU = 1500;
const FAMILY_IPV4 = 1;

interface CoreOptions {
  homeDir: string;
  configPath: string;
  tunFd: number;
  controller: string;
  secret: string;
  stack: string;
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;

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
    core.stop();
    this.connection?.destroy();
  }

  private async start(): Promise<void> {
    const filesDir = this.context.filesDir;
    const runtime = readRuntime(filesDir);
    if (runtime === undefined) {
      throw new Error('runtime.json missing, start the VPN from the app');
    }

    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    // The core's outbound sockets live in this process; keep them off the VPN.
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
      mtu: TUN_MTU
    };
    const tunFd = await connection.create(config);
    hilog.info(DOMAIN, TAG, 'tun created, fd=%{public}d', tunFd);

    const options: CoreOptions = {
      homeDir: filesDir,
      configPath: runtime.configPath,
      tunFd: tunFd,
      controller: CONTROLLER_ADDRESS,
      secret: runtime.secret,
      stack: runtime.stack
    };
    await core.start(JSON.stringify(options));
    hilog.info(DOMAIN, TAG, 'core %{public}s started', core.version());
  }
}
