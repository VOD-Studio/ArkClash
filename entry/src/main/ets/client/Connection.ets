import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { OutboundMode, setAllowLan, setMode } from './Controller';
import { probeCore, startCore, stopCore } from './CoreClient';

// 只用来让首帧和上次的状态一致，真实状态以 probeCore 为准。
const PREF_CONNECTED = 'lastConnected';
const PREF_CONNECTED_AT = 'connectedAt';
const PREF_CONNECT_DURATION = 'lastConnectDuration';
// 用户选的出站模式；空串 = 沿用配置文件里的 mode。
const PREF_MODE = 'outboundMode';
// 局域网代理开关；用户没动过时沿用配置文件里的 allow-lan。
const PREF_ALLOW_LAN = 'allowLan';

export enum ConnectionState {
  Disconnected,
  Connecting,
  Connected,
  Disconnecting
}

@ObservedV2
export class Connection {
  @Trace state: ConnectionState = ConnectionState.Disconnected;
  @Trace coreVersion: string = '';
  @Trace error: string = '';
  @Trace connectedAt: number = 0; // ms，0 = 未知
  @Trace connectDuration: number = 0; // 上次从点连接到内核就绪用了多久，ms；0 = 未知
  @Trace mode: OutboundMode | '' = '';
  @Trace allowLan: boolean | undefined = undefined; // undefined = 用户没设置过
  private prefs?: preferences.Preferences;
  private filesDir: string = '';

  get busy(): boolean {
    return this.state === ConnectionState.Connecting || this.state === ConnectionState.Disconnecting;
  }

  get connected(): boolean {
    return this.state === ConnectionState.Connected;
  }

  /** 先用缓存的状态渲染，再在后台向内核确认。 */
  restore(context: common.UIAbilityContext): void {
    this.filesDir = context.filesDir;
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    this.mode = this.prefs.getSync(PREF_MODE, '') as OutboundMode | '';
    this.connectDuration = this.prefs.getSync(PREF_CONNECT_DURATION, 0) as number;
    if (this.prefs.hasSync(PREF_ALLOW_LAN)) {
      this.allowLan = this.prefs.getSync(PREF_ALLOW_LAN, false) as boolean;
    }
    if (this.prefs.getSync(PREF_CONNECTED, false) as boolean) {
      this.state = ConnectionState.Connected;
      this.connectedAt = this.prefs.getSync(PREF_CONNECTED_AT, 0) as number;
    }
    probeCore(context).then((version: string | undefined) => {
      if (this.busy) {
        return;
      }
      if (version === undefined) {
        this.settle(ConnectionState.Disconnected);
      } else {
        this.coreVersion = version;
        this.settle(ConnectionState.Connected);
      }
    });
  }

  async connect(context: common.UIAbilityContext): Promise<void> {
    if (this.busy) {
      return;
    }
    this.error = '';
    this.state = ConnectionState.Connecting;
    const begin = Date.now();
    try {
      this.coreVersion = await startCore(context);
      this.connectedAt = Date.now();
      this.connectDuration = this.connectedAt - begin;
      this.prefs?.putSync(PREF_CONNECT_DURATION, this.connectDuration);
      this.settle(ConnectionState.Connected);
      if (this.mode !== '') {
        await setMode(this.filesDir, this.mode);
      }
      if (this.allowLan !== undefined) {
        await setAllowLan(this.filesDir, this.allowLan);
      }
    } catch (e) {
      this.error = (e as Error).message;
      if (this.state === ConnectionState.Connecting) {
        this.settle(ConnectionState.Disconnected);
      }
    }
  }

  async disconnect(context: common.UIAbilityContext): Promise<void> {
    if (this.busy) {
      return;
    }
    this.error = '';
    this.state = ConnectionState.Disconnecting;
    try {
      await stopCore(context);
      this.settle(ConnectionState.Disconnected);
    } catch (e) {
      this.error = (e as Error).message;
      this.settle(ConnectionState.Connected);
    }
  }

  /** 记住用户选的模式；连接中立即下发给内核。 */
  async changeMode(mode: OutboundMode): Promise<void> {
    const previous = this.mode;
    this.mode = mode;
    this.prefs?.putSync(PREF_MODE, mode);
    this.prefs?.flush();
    if (this.connected) {
      try {
        await setMode(this.filesDir, mode);
      } catch (e) {
        this.mode = previous;
        this.error = (e as Error).message;
      }
    }
  }

  /** 记住局域网代理开关；连接中立即下发给内核。 */
  async changeAllowLan(allow: boolean): Promise<void> {
    const previous = this.allowLan;
    this.allowLan = allow;
    this.prefs?.putSync(PREF_ALLOW_LAN, allow);
    this.prefs?.flush();
    if (this.connected) {
      try {
        await setAllowLan(this.filesDir, allow);
      } catch (e) {
        this.allowLan = previous;
        this.error = (e as Error).message;
      }
    }
  }

  private settle(state: ConnectionState): void {
    this.state = state;
    if (state === ConnectionState.Disconnected) {
      this.connectedAt = 0;
    }
    this.prefs?.putSync(PREF_CONNECTED, state === ConnectionState.Connected);
    this.prefs?.putSync(PREF_CONNECTED_AT, this.connectedAt);
    this.prefs?.flush();
  }
}

/** UI 进程里唯一的连接状态，首页、代理组等页面共用。 */
export const connection: Connection = new Connection();
