export function logLevelLabel(level: string): Resource {
  switch (level) {
    case 'debug': return $r('app.string.general_log_debug');
    case 'info': return $r('app.string.general_log_info');
    case 'warning': return $r('app.string.general_log_warning');
    case 'silent': return $r('app.string.general_log_silent');
    default: return $r('app.string.general_log_error');
  }
}
