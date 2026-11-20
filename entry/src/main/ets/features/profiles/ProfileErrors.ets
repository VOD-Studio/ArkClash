import { errorCode, errorDetail } from '../../shared/profiles/Errors';

export function describeError(error: string): ResourceStr {
  switch (errorCode(error)) {
    case 'http': return $r('app.string.err_http', errorDetail(error));
    case 'not_clash': return $r('app.string.err_not_clash');
    case 'invalid_yaml': return $r('app.string.err_invalid_yaml', '');
    case 'rejected': return $r('app.string.err_rejected', '');
    case 'network': return $r('app.string.err_network', '');
    case 'io': return $r('app.string.err_io', '');
    case 'not_found': return $r('app.string.err_not_found');
    case 'busy': return $r('app.string.err_busy');
    case 'host_unknown': return $r('app.string.profile_err_host_unknown');
    case 'name_taken': return $r('app.string.err_name_taken');
    case 'name_empty': return $r('app.string.err_name_empty');
    case 'name_long': return $r('app.string.profile_err_name_long');
    case 'link_exists': return $r('app.string.err_link_exists');
    case 'interval_invalid': return $r('app.string.err_interval');
    case 'in_use': return $r('app.string.profile_in_use_hint');
    case 'conflict': return $r('app.string.profile_err_conflict');
    case 'corrupt': return $r('app.string.profile_err_corrupt');
    case 'url_invalid': return $r('app.string.profile_err_url');
    case 'import_link_invalid': return $r('app.string.profile_err_import_link');
    case 'proxy_link_invalid':
    case 'local_proxy_input': return $r('app.string.local_proxy_link');
    case 'local_proxy_core_unavailable': return $r('app.string.local_proxy_core_unavailable');
    case 'qr_invalid': return $r('app.string.profile_err_import_link');
    case 'qr_camera': return $r('app.string.profile_qr_camera_error');
    case 'qr_photo': return $r('app.string.profile_qr_photo_error');
    case 'age_required': return $r('app.string.profile_age_required');
    case 'age_decrypt': return $r('app.string.profile_age_decrypt');
    case 'age_core_unavailable': return $r('app.string.profile_age_core_unavailable');
    case 'canceled': return $r('app.string.profile_err_canceled');
    case 'timeout': return $r('app.string.profile_err_timeout');
    case 'dns': return $r('app.string.profile_err_dns');
    case 'tls': return $r('app.string.profile_err_tls');
    case 'apply_failed': return $r('app.string.profile_err_apply');
    case 'added_rules_match_target': return $r('app.string.standard_match_target_missing');
    case 'metadata_saved': return $r('app.string.profile_metadata_saved');
    case 'unsupported_input': return $r('app.string.profile_err_unsupported_input');
    default: return $r('app.string.err_network', '');
  }
}
