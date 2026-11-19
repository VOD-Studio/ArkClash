import { errorCode, errorString } from '../../shared/profiles/Errors';
import { describeError } from './ProfileErrors';

export function configScriptError(error: Object): ResourceStr {
  const code = (error as Error).message ?? '';
  const stage = errorCode(code);
  let message: ResourceStr;
  switch (stage) {
    case 'script_store': return $r('app.string.script_err_store');
    case 'script_missing': return $r('app.string.script_err_missing');
    case 'script_conflict': return $r('app.string.profile_err_conflict');
    case 'script_empty': return $r('app.string.script_err_empty');
    case 'script_encoding': return $r('app.string.script_err_encoding');
    case 'script_size': return $r('app.string.script_err_size');
    case 'script_config': case 'script_input': return $r('app.string.script_err_config');
    case 'script_syntax': message = $r('app.string.script_err_syntax'); break;
    case 'script_execution': case 'script_rejection': message = $r('app.string.script_err_execution'); break;
    case 'script_entry': return $r('app.string.script_err_entry');
    case 'script_pending': return $r('app.string.script_err_pending');
    case 'script_return': message = $r('app.string.script_err_return'); break;
    case 'script_timeout': return $r('app.string.script_err_timeout');
    case 'script_memory': return $r('app.string.script_err_memory');
    case 'script_stack': message = $r('app.string.script_err_stack'); break;
    case 'script_apply': return $r('app.string.profile_err_apply');
    case 'profile_settings_invalid': return $r('app.string.added_rules_invalid');
    case 'profile_settings_conflict': return $r('app.string.added_rules_conflict');
    default: return describeError(errorString(error));
  }
  const match = new RegExp('^script_[a-z]+:([0-9]+):([0-9]+)$').exec(code);
  if (match === null) { return message; }
  return $r('app.string.script_err_position', message, match[1], match[2]);
}
