import { http } from '@kit.NetworkKit';
import { ProfileError } from '../shared/profiles/Errors';
import { UpdateOutcome } from '../shared/profiles/Updater';
import { call, RuntimeStatus } from './Controller';
import { ControllerSocket } from './ControllerSocket';

const COMMAND_TIMEOUT_MS = 90000;

interface ClientProfileUpdateCommand {
  subscription: string;
  url?: string;
}

interface ClientProfileAddCommand {
  profile: string;
  subscription: string;
  url: string;
  label: string;
  ageSecretKey?: string;
}

export interface ProfileEvent {
  type: string;
  subscription?: string;
  profile?: string;
  ok?: boolean;
  status?: RuntimeStatus;
}

async function command(filesDir: string, name: string, body: Object): Promise<string> {
  return await call(filesDir, http.RequestMethod.POST, `/arkclash/profiles/${name}`, JSON.stringify(body),
    COMMAND_TIMEOUT_MS);
}

function parseOutcome(text: string): UpdateOutcome {
  try {
    const outcome = JSON.parse(text) as UpdateOutcome;
    if (typeof outcome.subscription !== 'string' || typeof outcome.ok !== 'boolean' || outcome.state === undefined) {
      throw new ProfileError('corrupt');
    }
    return outcome;
  } catch (e) {
    throw new ProfileError('corrupt');
  }
}

export async function updateViaVpn(filesDir: string, subscription: string, source?: string): Promise<UpdateOutcome> {
  const body: ClientProfileUpdateCommand = { subscription: subscription, url: source };
  return parseOutcome(await command(filesDir, 'update', body));
}

export async function addViaVpn(filesDir: string, profile: string, subscription: string,
  source: string, label: string = '', ageSecretKey: string = ''): Promise<UpdateOutcome> {
  const body: ClientProfileAddCommand = { profile: profile, subscription: subscription, url: source, label: label,
    ageSecretKey: ageSecretKey === '' ? undefined : ageSecretKey };
  return parseOutcome(await command(filesDir, 'add', body));
}

export async function notifyListChanged(filesDir: string): Promise<void> {
  await command(filesDir, 'changed', new Object());
}

export class ProfileEvents {
  private socket: ControllerSocket;

  constructor(onEvent: (event: ProfileEvent) => void) {
    this.socket = new ControllerSocket('/arkclash/events', (text: string): void => {
      try {
        const event = JSON.parse(text) as ProfileEvent;
        if (event.type === 'updated' || event.type === 'reloaded' || event.type === 'runtime') { onEvent(event); }
      } catch (e) {
        // 事件损坏不改本地实体；重新进入前台会从磁盘和运行状态恢复。
      }
    });
  }

  start(filesDir: string): void { this.socket.start(filesDir); }
  stop(): void { this.socket.stop(); }
}
