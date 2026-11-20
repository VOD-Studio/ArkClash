// 状态与命令只保存脱敏错误码；解析器、网络和内核的原始消息可能含订阅凭据。
export class ProfileError extends Error {
  constructor(code: string, detail?: string) {
    const safeDetail = code === 'http' && detail !== undefined && new RegExp('^[1-5][0-9]{2}$').test(detail) ?
      `:${detail}` : '';
    super(`${code}${safeDetail}`);
  }
}

const CODES: string[] = ['http', 'not_clash', 'invalid_yaml', 'rejected', 'network', 'io', 'not_found', 'busy',
  'conflict', 'canceled', 'timeout', 'dns', 'tls', 'corrupt', 'url_invalid', 'name_empty', 'name_taken',
  'name_long', 'link_exists', 'interval_invalid', 'in_use', 'unsupported_input', 'age_required', 'apply_failed',
  'metadata_saved', 'host_unknown', 'script_empty', 'script_encoding', 'script_size', 'script_store', 'script_conflict',
  'icon_set_input', 'icon_set_invalid', 'icon_set_size', 'icon_set_download', 'icon_set_conflict',
  'added_rules_match_target', 'import_link_invalid', 'proxy_link_invalid', 'local_proxy_input', 'local_proxy_core_unavailable'];

export function errorString(error: Object): string {
  const message = (error as Error).message ?? '';
  const code = errorCode(message);
  if (CODES.includes(code)) {
    return new ProfileError(code, errorDetail(message)).message;
  }
  const lower = message.toLowerCase();
  if (lower.includes('timeout') || lower.includes('timed out')) {
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
