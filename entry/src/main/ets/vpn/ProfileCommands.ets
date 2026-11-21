import core from 'libarkclash.so';
import { handleScriptDownload } from './ScriptUpdates';
import { ProfileError } from '../shared/profiles/Errors';
import { IconSetDownloadCommand } from '../shared/profiles/IconSetModel';
import { downloadIconSet } from '../shared/profiles/IconSets';
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
  ageSecretKey?: string;
}

interface VpnProfileOkReply { ok: boolean; }
interface VpnProfileUpdatedEvent { type: string; subscription: string; ok: boolean; }

export async function handleProfileCommand(scheduler: UpdateScheduler, env: UpdateEnv,
  name: string, body: string): Promise<Object> {
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
      if (command.ageSecretKey !== undefined && typeof command.ageSecretKey !== 'string') {
        throw new ProfileError('age_decrypt');
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
        command.label ?? '', eligible, command.ageSecretKey ?? '');
    }
    case 'script-download':
      return handleScriptDownload(env.filesDir, env.downloader, body, eligible);
    case 'icon-set-download': {
      await downloadIconSet(env.filesDir, env.downloader, JSON.parse(body) as IconSetDownloadCommand, eligible);
      const reply: VpnProfileOkReply = { ok: true };
      return reply;
    }
    case 'changed': {
      scheduler.reschedule();
      const reply: VpnProfileOkReply = { ok: true };
      return reply;
    }
    default: throw new ProfileError('unsupported_input');
  }
}

export function emitUpdated(outcome: UpdateOutcome): void {
  const event: VpnProfileUpdatedEvent = { type: 'updated', subscription: outcome.subscription, ok: outcome.ok };
  core.emit(JSON.stringify(event));
}
