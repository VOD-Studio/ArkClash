// 后台保持连接（ADR-0038）。用户开启后，连接期间由界面进程申请数据传输长时任务：
// 界面在后台不被挂起，回收优先级降到 200，绑定的 VPN 进程随之降到 300；
// 宿主被回收时界面能在后台立即恢复连接。默认关闭：任务带常驻通知，且界面进程不再被冻结。
import { AbilityConstant, common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { statistics } from '@kit.NetworkKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0A11;
const TAG = 'BackgroundKeep';
const PREF_KEEP = 'backgroundKeep';
const TUN_NAME = 'vpn-tun';
// 数据传输长时任务必须在 10 分钟内更新实况窗进度，否则系统取消任务。
const PROGRESS_INTERVAL_MS = 5 * 60 * 1000;
// 进度条按隧道累计流量循环，每 64 MiB 一圈。
const PROGRESS_WINDOW_BYTES = 64 * 1024 * 1024;
// 刚收到严重内存压力时推迟恢复，避免新宿主启动峰值再次触发回收。
const PRESSURE_DELAY_MS = 30000;
const PRESSURE_LEVELS: AbilityConstant.MemoryLevel[] = [
  AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL, AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_CRITICAL
];

// off：未开启；idle：已开启但未连接；active：任务运行中；suspended：系统暂停；
// stopped：系统取消，回到前台重新申请；removed：用户移除通知，下次连接时恢复；failed：申请被拒。
export type BackgroundKeepState = 'off' | 'idle' | 'active' | 'suspended' | 'stopped' | 'removed' | 'failed';

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${Math.max(0, Math.round(bytes))} B`;
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    ++unit;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

@ObservedV2
export class BackgroundKeep {
  @Trace enabled: boolean = false;
  @Trace state: BackgroundKeepState = 'off';
  private context?: common.UIAbilityContext;
  private prefs?: preferences.Preferences;
  private wanted: boolean = false;
  private removedByUser: boolean = false;
  private task?: backgroundTaskManager.ContinuousTaskNotification;
  private agent?: WantAgent;
  private timer: number = -1;
  private work: Promise<void> = Promise.resolve();
  private listening: boolean = false;
  private pressureUntil: number = 0;

  /** 界面在后台时回调能否及时执行：任务被暂停时界面同样会被挂起。 */
  get running(): boolean {
    return this.task !== undefined && this.state === 'active';
  }

  restore(context: common.UIAbilityContext): void {
    this.context = context;
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    this.enabled = this.prefs.getSync(PREF_KEEP, false) as boolean;
    this.listen(context);
    this.reconcile();
  }

  /** 用户开启时先确认通知可用：实况窗发不出去，任务 10 分钟后就会被系统取消。 */
  async setEnabled(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    if (enabled && !await this.notificationsAllowed(context)) {
      throw new Error('keep_notification_disabled');
    }
    this.prefs?.putSync(PREF_KEEP, enabled);
    await this.prefs?.flush();
    this.enabled = enabled;
    this.removedByUser = false;
    this.reconcile();
  }

  /** 用户希望保持连接时持有任务；宿主恢复期间保持不变。 */
  sync(wanted: boolean): void {
    if (wanted && !this.wanted) {
      this.removedByUser = false;
    }
    this.wanted = wanted;
    this.reconcile();
  }

  /** 系统取消或申请失败后，回到前台再申请一次。 */
  foreground(): void {
    if (this.state === 'stopped' || this.state === 'failed') {
      this.reconcile();
    }
  }

  pressureDelayMs(): number {
    return Math.max(0, this.pressureUntil - Date.now());
  }

  private async notificationsAllowed(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (_error) {
      return false;
    }
  }

  private reconcile(): void {
    this.work = this.work.then((): Promise<void> => this.apply()).catch((): void => {});
  }

  private desired(): boolean {
    return this.enabled && this.wanted && !this.removedByUser;
  }

  private async apply(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    if (this.desired() && this.task === undefined) {
      await this.start(context);
    } else if (!this.desired() && this.task !== undefined) {
      await this.stop(context);
    }
    if (!this.enabled) {
      this.state = 'off';
    } else if (this.task === undefined && (!this.wanted || this.state === 'active' || this.state === 'suspended')) {
      this.state = 'idle';
    }
  }

  private async start(context: common.UIAbilityContext): Promise<void> {
    try {
      if (this.agent === undefined) {
        this.agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
      }
      const task = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], this.agent);
      this.task = task;
      this.state = 'active';
      hilog.info(DOMAIN, TAG, 'continuous task started');
      await this.publish();
      clearInterval(this.timer);
      this.timer = setInterval((): void => { this.publish(); }, PROGRESS_INTERVAL_MS);
    } catch (error) {
      this.state = 'failed';
      hilog.warn(DOMAIN, TAG, 'continuous task refused %{public}d', (error as BusinessError).code ?? -1);
    }
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    clearInterval(this.timer);
    this.timer = -1;
    this.task = undefined;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      hilog.info(DOMAIN, TAG, 'continuous task stopped');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'continuous task stop failed %{public}d', (error as BusinessError).code ?? -1);
    }
  }

  // 实况窗显示隧道累计流量，进度随流量前进，满足数据传输任务的进度更新要求。
  private async publish(): Promise<void> {
    const task = this.task;
    const context = this.context;
    if (task === undefined || context === undefined) {
      return;
    }
    let received = 0;
    let sent = 0;
    try {
      received = await statistics.getIfaceRxBytes(TUN_NAME);
      sent = await statistics.getIfaceTxBytes(TUN_NAME);
    } catch (_error) {
      // 隧道正在重建时读不到计数，照常更新进度。
    }
    if (this.task !== task) {
      return;
    }
    const title = context.resourceManager.getStringByNameSync('keep_notification_title');
    const text = context.resourceManager.getStringByNameSync('keep_notification_text', formatBytes(sent),
      formatBytes(received));
    const progress = Math.floor(((received + sent) % PROGRESS_WINDOW_BYTES) * 100 / PROGRESS_WINDOW_BYTES);
    const request: notificationManager.NotificationRequest = {
      id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: title, text: text }
      },
      template: { name: 'downloadTemplate', data: { title: title, fileName: text, progressValue: progress } }
    };
    try {
      await notificationManager.publish(request);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'progress update failed %{public}d', (error as BusinessError).code ?? -1);
    }
  }

  private listen(context: common.UIAbilityContext): void {
    if (this.listening) {
      return;
    }
    this.listening = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
        if (this.task === undefined || info.id !== this.task.continuousTaskId) {
          return;
        }
        clearInterval(this.timer);
        this.timer = -1;
        this.task = undefined;
        const byUser = info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
          info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION;
        this.removedByUser = byUser;
        this.state = byUser ? 'removed' : 'stopped';
        hilog.info(DOMAIN, TAG, 'continuous task cancelled %{public}d/%{public}d', info.reason,
          info.detailedReason ?? -1);
      });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          if (this.task !== undefined && info.continuousTaskId === this.task.continuousTaskId) {
            this.state = 'suspended';
            hilog.info(DOMAIN, TAG, 'continuous task suspended %{public}d', info.suspendReason);
          }
        });
      backgroundTaskManager.on('continuousTaskActive', (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
        if (this.task !== undefined && info.id === this.task.continuousTaskId) {
          this.state = 'active';
          hilog.info(DOMAIN, TAG, 'continuous task active');
        }
      });
    } catch (_error) {
      hilog.warn(DOMAIN, TAG, 'continuous task listeners unavailable');
    }
    try {
      context.getApplicationContext().on('environment', {
        onConfigurationUpdated: (): void => {},
        onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => {
          if (PRESSURE_LEVELS.includes(level)) {
            this.pressureUntil = Date.now() + PRESSURE_DELAY_MS;
          }
        }
      });
    } catch (_error) {
      hilog.warn(DOMAIN, TAG, 'memory pressure listener unavailable');
    }
  }
}

export const backgroundKeep: BackgroundKeep = new BackgroundKeep();
