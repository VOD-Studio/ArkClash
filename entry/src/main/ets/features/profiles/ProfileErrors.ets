import { errorCode, errorDetail } from '../../shared/profiles/Errors';
import { ERR_INTERVAL, ERR_IN_USE, ERR_LINK_EXISTS, ERR_NAME_EMPTY, ERR_NAME_TAKEN } from './Profiles';

/** 把 Errors.ets 格式的错误翻成界面文字；不认识的代码原样显示。 */
export function describeError(error: string): ResourceStr {
  const detail = errorDetail(error);
  switch (errorCode(error)) {
    case 'http':
      return $r('app.string.err_http', detail);
    case 'not_clash':
      return $r('app.string.err_not_clash');
    case 'invalid_yaml':
      return $r('app.string.err_invalid_yaml', detail);
    case 'rejected':
      return $r('app.string.err_rejected', detail);
    case 'network':
      return $r('app.string.err_network', detail);
    case 'io':
      return $r('app.string.err_io', detail);
    case 'not_found':
      return $r('app.string.err_not_found');
    case 'busy':
      return $r('app.string.err_busy');
    case ERR_NAME_TAKEN:
      return $r('app.string.err_name_taken');
    case ERR_NAME_EMPTY:
      return $r('app.string.err_name_empty');
    case ERR_LINK_EXISTS:
      return $r('app.string.err_link_exists');
    case ERR_INTERVAL:
      return $r('app.string.err_interval');
    case ERR_IN_USE:
      return $r('app.string.profile_in_use_hint');
    default:
      return error;
  }
}
