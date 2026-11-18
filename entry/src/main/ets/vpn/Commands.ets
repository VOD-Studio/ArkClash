import core from 'libarkclash.so';
import { errorString } from '../shared/profiles/Errors';
import { UpdateEnv, UpdateScheduler } from '../shared/profiles/Updater';
import { handleProfileCommand } from './ProfileCommands';

export class VpnCommandError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface VpnCommandErrorReply { message: string; }

async function routeCommand(scheduler: UpdateScheduler, env: UpdateEnv,
  vpnHandler: (name: string, body: string) => Promise<Object>, name: string, body: string): Promise<Object> {
  try {
    const parsed = JSON.parse(body) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new VpnCommandError(400, 'unsupported_input');
    }
  } catch (_error) {
    throw new VpnCommandError(400, 'unsupported_input');
  }
  switch (name) {
    case 'profiles/update':
    case 'profiles/add':
    case 'profiles/changed':
      return handleProfileCommand(scheduler, env, name.substring('profiles/'.length), body);
    case 'vpn/connect':
    case 'vpn/disconnect':
      return vpnHandler(name.substring('vpn/'.length), body);
    default:
      throw new VpnCommandError(400, 'unsupported_input');
  }
}

export function serveCommands(scheduler: UpdateScheduler, env: UpdateEnv,
  vpnHandler: (name: string, body: string) => Promise<Object>): void {
  core.onCommand((id: number, name: string, body: string): void => {
    routeCommand(scheduler, env, vpnHandler, name, body).then((result: Object): void => {
      core.reply(id, 200, JSON.stringify(result));
    }).catch((error: Error): void => {
      let status = 500;
      let message = errorString(error);
      if (error instanceof VpnCommandError) {
        status = error.status;
        message = error.message;
      } else if (message === 'conflict' || message === 'canceled' || message === 'busy') {
        status = 409;
      } else if (message === 'not_found') {
        status = 404;
      } else if (message === 'unsupported_input' || message === 'url_invalid') {
        status = 400;
      }
      const reply: VpnCommandErrorReply = { message: message };
      core.reply(id, status, JSON.stringify(reply));
    });
  });
}
