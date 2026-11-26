import { LogRecord } from '../../client/Logs';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export function logClock(time: number): string {
  const date = new Date(time);
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`;
}

export function logTimestamp(time: number): string {
  const date = new Date(time);
  const month = pad2(date.getMonth() + 1);
  const day = pad2(date.getDate());
  const ms = String(date.getMilliseconds()).padStart(3, '0');
  return `${date.getFullYear()}-${month}-${day} ${logClock(time)}.${ms}`;
}

export function logCopyText(record: LogRecord, summary: string): string {
  const body = summary === record.message ? record.message : summary + '\n' + record.message;
  return `${logTimestamp(record.time)} [${record.level}] ${body}`;
}

export function logHasRoute(record: LogRecord): boolean {
  return (record.target ?? '') !== '' && ((record.proxy ?? '') !== '' || record.event === 'dial_failed');
}

export function logHasDns(record: LogRecord): boolean {
  const event = record.event ?? '';
  return (record.target ?? '') !== '' && (event.startsWith('dns_') || event === 'sniffer');
}

export function logLevelLabel(level: string): Resource {
  switch (level) {
    case 'debug': return $r('app.string.general_log_debug');
    case 'info': return $r('app.string.general_log_info');
    case 'warning': return $r('app.string.general_log_warning');
    case 'silent': return $r('app.string.general_log_silent');
    default: return $r('app.string.general_log_error');
  }
}

export function logDialReasonLabel(reason: string): Resource {
  switch (reason) {
    case 'timeout': return $r('app.string.log_dial_timeout');
    case 'certificate': return $r('app.string.log_dial_certificate');
    case 'connection refused': return $r('app.string.log_dial_refused');
    case 'no such host': return $r('app.string.log_dial_host');
    case 'network is unreachable': return $r('app.string.log_dial_network');
    case 'authentication': return $r('app.string.log_dial_auth');
    default: return $r('app.string.log_dial_failed');
  }
}

export function logSummaryLabel(record: LogRecord): ResourceStr {
  switch (record.event) {
    case 'route_selected': return $r('app.string.log_route_selected');
    case 'route_direct': return $r('app.string.log_route_direct');
    case 'dns_udp': return $r('app.string.log_dns_udp');
    case 'dns_tcp': return $r('app.string.log_dns_tcp');
    case 'dns_cache': return $r('app.string.log_dns_cache');
    case 'dns_query': return $r('app.string.log_dns_query');
    case 'dns_answer': return $r('app.string.log_dns_answer');
    case 'dns_failed': return $r('app.string.log_dns_failed');
    case 'default_rules': return $r('app.string.log_default_rules');
    case 'named_rules': return $r('app.string.log_named_rules');
    case 'vision_direct': return $r('app.string.log_vision_direct');
    case 'core_started': return $r('app.string.log_core_started');
    case 'controller_unavailable': return $r('app.string.log_controller_unavailable');
    case 'vpn_cleanup': return $r('app.string.log_vpn_cleanup');
    case 'profile_reloaded': return $r('app.string.log_profile_reloaded');
    case 'dial_failed': return logDialReasonLabel(record.reason ?? '');
    case 'sniffer': return $r('app.string.log_sniffer_ok');
    case 'port_hop': return $r('app.string.log_port_hop');
    case 'component':
    case 'template':
      return record.message;
    case 'other': return $r('app.string.log_other');
    default: return record.message === 'Core event' ? $r('app.string.log_other') : record.message;
  }
}
