import core from 'libarkclash.so';
import { errorString, ProfileError } from '../shared/profiles/Errors';
import { checkProfileCommit, findProfile, readListAsync, readStateAsync, validProfileId } from '../shared/profiles/Store';
import { downloadNewSubscription, UpdateEnv, UpdateOutcome, UpdateScheduler } from '../shared/profiles/Updater';

interface VpnProfileUpdateCommand {
  subscription: string;
  url?: string;
}

interface VpnProfileAddCommand {
  profile: string;
  subscription: string;
  url: string;
  label?: string;
}

interface VpnProfileErrorReply { message: string; }
interface VpnProfileOkReply { ok: boolean; }
interface VpnProfileUpdatedEvent { type: string; subscription: string; ok: boolean; }

function send(id: number, status: number, body: Object): void {
  core.reply(id, status, JSON.stringify(body));
}

async function handle(scheduler: UpdateScheduler, env: UpdateEnv, name: string, body: string): Promise<Object> {
  const generation = scheduler.operationGeneration();
  const eligible = (): boolean => scheduler.acceptsGeneration(generation) && env.eligible?.() !== false;
  checkProfileCommit(eligible);
  switch (name) {
    case 'update': {
      const command = JSON.parse(body) as VpnProfileUpdateCommand;
      if (typeof command.subscription !== 'string' || !validProfileId(command.subscription)) {
        throw new ProfileError('not_found');
      }
      const outcome = await scheduler.update(command.subscription, command.url);
      checkProfileCommit(eligible);
      return outcome;
    }
    case 'add': {
      const command = JSON.parse(body) as VpnProfileAddCommand;
      if (typeof command.profile !== 'string' || !validProfileId(command.profile) ||
        typeof command.subscription !== 'string' || !validProfileId(command.subscription) ||
        typeof command.url !== 'string') {
        throw new ProfileError('url_invalid');
      }
      const saved = findProfile(await readListAsync(env.filesDir), command.profile);
      if (saved !== undefined) {
        if (saved.subscription !== command.subscription) { throw new ProfileError('conflict'); }
        const reply: UpdateOutcome = { subscription: command.subscription, ok: true,
          state: await readStateAsync(env.filesDir, command.subscription) };
        checkProfileCommit(eligible);
        return reply;
      }
      return await downloadNewSubscription(env, command.profile, command.subscription, command.url,
        command.label ?? '', eligible);
    }
    case 'changed': {
      scheduler.reschedule();
      const reply: VpnProfileOkReply = { ok: true };
      return reply;
    }
    default: throw new ProfileError('unsupported_input');
  }
}

export function serveProfileCommands(scheduler: UpdateScheduler, env: UpdateEnv): void {
  core.onCommand((id: number, name: string, body: string): void => {
    handle(scheduler, env, name, body).then((result: Object): void => {
      send(id, 200, result);
    }).catch((error: Error): void => {
      const reply: VpnProfileErrorReply = { message: errorString(error) };
      send(id, 500, reply);
    });
  });
}

export function emitUpdated(outcome: UpdateOutcome): void {
  const event: VpnProfileUpdatedEvent = { type: 'updated', subscription: outcome.subscription, ok: outcome.ok };
  core.emit(JSON.stringify(event));
}
