// 连接中把订阅类操作交给 VPN 进程（ADR-0009），格式与 vpn/ProfileCommands.ets 一致。
import { http } from '@kit.NetworkKit';
import { UpdateOutcome } from '../shared/profiles/Updater';
import { call } from './Controller';
import { ControllerSocket } from './ControllerSocket';

// 和 core/api.go 的 commandTimeout 对齐，多留几秒给回复路上的开销。
const COMMAND_TIMEOUT_MS = 155000;

interface UpdateCommand {
  subscription: string;
  url?: string;
}

interface AddCommand {
  profile: string;
  subscription: string;
  url: string;
}

/** VPN 进程推来的事件：'updated' 带 subscription，'reloaded' 带 profile。 */
export interface ProfileEvent {
  type: string;
  subscription?: string;
  profile?: string;
  ok?: boolean;
}

async function command(filesDir: string, name: string, body: Object): Promise<string> {
  return await call(filesDir, http.RequestMethod.POST, `/arkclash/profiles/${name}`, JSON.stringify(body),
    COMMAND_TIMEOUT_MS);
}

/** 更新订阅；url 用于修改链接。结果同时写进了状态文件。 */
export async function updateViaVpn(filesDir: string, subscription: string, url?: string): Promise<UpdateOutcome> {
  const body: UpdateCommand = { subscription: subscription, url: url };
  return JSON.parse(await command(filesDir, 'update', body)) as UpdateOutcome;
}

/** 新加的订阅第一次下载，成功后由界面写进列表。 */
export async function addViaVpn(filesDir: string, profile: string, subscription: string,
  url: string): Promise<UpdateOutcome> {
  const body: AddCommand = { profile: profile, subscription: subscription, url: url };
  return JSON.parse(await command(filesDir, 'add', body)) as UpdateOutcome;
}

/** 列表里的订阅或更新设置变了，让 VPN 进程重新安排自动更新。 */
export async function notifyListChanged(filesDir: string): Promise<void> {
  await command(filesDir, 'changed', new Object());
}

/** 订阅 VPN 进程的事件推送；页面可见时 start，不可见时 stop。 */
export class ProfileEvents {
  private socket: ControllerSocket;

  constructor(onEvent: (event: ProfileEvent) => void) {
    this.socket = new ControllerSocket('/arkclash/events', (text: string) => {
      onEvent(JSON.parse(text) as ProfileEvent);
    });
  }

  start(filesDir: string): void {
    this.socket.start(filesDir);
  }

  stop(): void {
    this.socket.stop();
  }
}
