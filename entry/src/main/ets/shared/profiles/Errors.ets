// 状态与命令只保存脱敏错误码；解析器、网络和内核的原始消息可能含订阅凭据。
export class ProfileError extends Error {
  constructor(code: string, detail?: string) {
    let safeDetail = '';
    if (code === 'http' && detail !== undefined && new RegExp('^[1-5][0-9]{2}$').test(detail)) {
      safeDetail = `:${detail}`;
    } else if (code === 'invalid_yaml' && detail !== undefined &&
      new RegExp('^[1-9][0-9]*:[1-9][0-9]*$').test(detail)) {
      safeDetail = `:${detail}`;
    }
    super(`${code}${safeDetail}`);
  }
}

const CODES: string[] = ['http', 'not_clash', 'invalid_yaml', 'rejected', 'network', 'io', 'not_found', 'busy',
  'conflict', 'canceled', 'timeout', 'dns', 'tls', 'corrupt', 'url_invalid', 'name_empty', 'name_taken',
  'name_long', 'link_exists', 'interval_invalid', 'in_use', 'unsupported_input', 'age_required', 'apply_failed',
  'metadata_saved', 'host_unknown', 'script_empty', 'script_encoding', 'script_size', 'script_store', 'script_conflict',
  'icon_set_input', 'icon_set_invalid', 'icon_set_size', 'icon_set_download', 'icon_set_conflict',
  'added_rules_match_target', 'import_link_invalid', 'proxy_link_invalid', 'local_proxy_input', 'local_proxy_core_unavailable',
  'qr_invalid', 'qr_camera', 'qr_photo', 'age_decrypt', 'age_core_unavailable',
  'preview_core_unavailable', 'preview_invalid_profile', 'preview_custom_tun', 'preview_too_large',
  'preview_build_failed', 'dns_override_proxy_servers_required', 'rule_set_in_use', 'rule_set_input'];

export function errorString(error: Object): string {
  const message = (error as Error).message ?? '';
  const code = errorCode(message);
  if (CODES.includes(code)) {
    return new ProfileError(code, errorDetail(message)).message;
  }
  const lower = message.toLowerCase();
  if (lower.includes('timeout') || lower.includes('timed out') || lower.includes('deadline exceeded')) {
    return 'timeout';
  }
  if (lower.includes('certificate') || lower.includes('ssl') || lower.includes('tls')) {
    return 'tls';
  }
  if (lower.includes('resolve') || lower.includes('dns')) {
    return 'dns';
  }
  return 'network';
}

export function errorCode(error: string): string {
  return error.split(':')[0];
}

export function errorDetail(error: string): string {
  const separator = error.indexOf(':');
  return separator < 0 ? '' : error.substring(separator + 1);
}
