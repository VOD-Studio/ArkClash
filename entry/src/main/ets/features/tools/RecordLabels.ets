export function recordColumnTitle(id: string): ResourceStr {
  switch (id) {
    case 'time': return $r('app.string.diagnostics_time');
    case 'target': return $r('app.string.diagnostics_target');
    case 'protocol': return $r('app.string.diagnostics_protocol');
    case 'network': return $r('app.string.diagnostics_network');
    case 'rule': return $r('app.string.diagnostics_rule');
    case 'rulePayload': return $r('app.string.diagnostics_rule_payload');
    case 'exit': return $r('app.string.diagnostics_exit');
    case 'traffic': return $r('app.string.diagnostics_traffic');
    case 'download': return $r('app.string.diagnostics_download');
    case 'upload': return $r('app.string.diagnostics_upload');
    case 'downloadSpeed': return $r('app.string.diagnostics_download_speed');
    case 'uploadSpeed': return $r('app.string.diagnostics_upload_speed');
    case 'duration': return $r('app.string.diagnostics_duration');
    case 'domain': return $r('app.string.diagnostics_domain');
    case 'type': return $r('app.string.diagnostics_type');
    case 'initiator': return $r('app.string.diagnostics_initiator');
    case 'result': return $r('app.string.diagnostics_result');
    case 'elapsed': return $r('app.string.diagnostics_elapsed');
    case 'upstream': return $r('app.string.diagnostics_upstream');
    case 'host': return $r('app.string.diagnostics_host');
    case 'source': return $r('app.string.diagnostics_source');
    case 'destination': return $r('app.string.diagnostics_destination');
    case 'sourceGeoIP': return $r('app.string.diagnostics_source_geo');
    case 'destinationGeoIP': return $r('app.string.diagnostics_destination_geo');
    case 'sourceIPASN': return $r('app.string.diagnostics_source_asn');
    case 'destinationIPASN': return $r('app.string.diagnostics_destination_asn');
    case 'dnsMode': return $r('app.string.diagnostics_dns_mode');
    case 'remoteDestination': return $r('app.string.diagnostics_remote_destination');
    case 'specialProxy': return $r('app.string.diagnostics_special_proxy');
    case 'specialRules': return $r('app.string.diagnostics_special_rules');
    case 'sniffHost': return $r('app.string.diagnostics_sniff_host');
    case 'chains': return $r('app.string.diagnostics_chains');
    case 'providerChains': return $r('app.string.diagnostics_provider_chains');
    case 'answers': return $r('app.string.diagnostics_answers');
    case 'error': return $r('app.string.diagnostics_error');
    case 'rcode': return $r('app.string.diagnostics_rcode');
    case 'cache': return $r('app.string.diagnostics_cache');
    default: return '';
  }
}

export function recordInitiatorText(initiator: string): ResourceStr {
  switch (initiator) {
    case 'app': return $r('app.string.diagnostics_initiator_app');
    case 'rule': return $r('app.string.diagnostics_initiator_rule');
    case 'direct': return $r('app.string.diagnostics_initiator_direct');
    case 'proxy': return $r('app.string.diagnostics_initiator_proxy');
    default: return $r('app.string.diagnostics_initiator_other');
  }
}

export function recordErrorText(code: string): ResourceStr {
  switch (code) {
    case 'diagnostics_invalid_request': return $r('app.string.diagnostics_invalid_request');
    case 'diagnostics_stale_runtime': return $r('app.string.diagnostics_stale_runtime');
    case 'diagnostics_not_ready': return $r('app.string.diagnostics_not_ready');
    case 'diagnostics_invalid_data': return $r('app.string.diagnostics_invalid_data');
    case 'diagnostics_stream_failed': return $r('app.string.diagnostics_stream_failed');
    case 'diagnostics_preferences_failed': return $r('app.string.diagnostics_preferences_failed');
    default: return $r('app.string.diagnostics_operation_failed');
  }
}

export function recordFacetText(field: string, value: string): ResourceStr {
  if (field === 'network' && value !== '') { return value.toUpperCase(); }
  if (field === 'initiator') { return recordInitiatorText(value); }
  if (field === 'cache' && value === 'true') { return $r('app.string.diagnostics_cached'); }
  if (field === 'cache' && value === 'false') { return $r('app.string.diagnostics_network_query'); }
  return value === '' ? $r('app.string.diagnostics_unknown') : value;
}
