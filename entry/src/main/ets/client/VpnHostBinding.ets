// 界面进程绑定正在运行的 VPN 扩展。系统按绑定方中最好的回收优先级加 100 计算扩展进程的优先级，
// 没有绑定时扩展固定为 500，先于普通后台应用被回收。绑定不承载业务调用；
// 断开回调同时是宿主进程退出的推送信号（ADR-0038）。
import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HOST_BINDING_PARAM } from '../shared/Runtime';

const DOMAIN = 0x0A11;
const TAG = 'VpnHostBinding';

export type HostLostListener = (bootId: string) => void;

class VpnHostBinding {
  private context?: common.UIAbilityContext;
  private connectionId: number = -1;
  // 已尝试绑定的宿主。绑定失败也记下，同一宿主不反复重试。
  private bootId: string = '';
  private connected: boolean = false;
  private listener?: HostLostListener;

  setListener(listener: HostLostListener): void {
    this.listener = listener;
  }

  /** 只在认证状态确认宿主运行后调用；同一宿主只绑定一次。 */
  bind(context: common.UIAbilityContext, bootId: string): void {
    if (bootId === '' || bootId === this.bootId) {
      return;
    }
    this.release().catch((): void => {});
    this.context = context;
    this.bootId = bootId;
    const parameters: Record<string, Object> = {};
    parameters[HOST_BINDING_PARAM] = true;
    const want: Want = {
      bundleName: context.applicationInfo.name, abilityName: 'ClashVpnAbility', parameters: parameters
    };
    try {
      this.connectionId = context.connectServiceExtensionAbility(want, {
        onConnect: (): void => {
          if (this.bootId === bootId) {
            this.connected = true;
            hilog.info(DOMAIN, TAG, 'host bound');
          }
        },
        onDisconnect: (): void => { this.lost(bootId); },
        onFailed: (code: number): void => {
          hilog.warn(DOMAIN, TAG, 'host binding failed %{public}d', code);
          this.lost(bootId);
        }
      });
    } catch (_error) {
      hilog.warn(DOMAIN, TAG, 'host binding unavailable');
      this.connectionId = -1;
    }
  }

  /** 停止扩展前先解绑：已绑定的扩展未必随 stop 立即销毁。 */
  async release(): Promise<void> {
    const context = this.context;
    const id = this.connectionId;
    this.connectionId = -1;
    this.connected = false;
    this.bootId = '';
    if (context === undefined || id < 0) {
      return;
    }
    try {
      await context.disconnectServiceExtensionAbility(id);
    } catch (_error) {
      // 宿主已经退出时连接也已失效。
    }
  }

  private lost(bootId: string): void {
    if (this.bootId !== bootId) {
      return;
    }
    const wasConnected = this.connected;
    this.connectionId = -1;
    this.connected = false;
    // 保留 bootId：同一宿主不再重绑，新宿主的 bootId 不同。
    const listener = this.listener;
    if (wasConnected && listener !== undefined) {
      hilog.info(DOMAIN, TAG, 'host lost');
      listener(bootId);
    }
  }
}

export const vpnHostBinding: VpnHostBinding = new VpnHostBinding();
