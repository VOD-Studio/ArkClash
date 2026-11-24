export function homeHasPendingCleanup(forward: string, listenersOpen: boolean, tunAttached: boolean,
  vpnCreated: boolean, hostState: string): boolean {
  return (hostState === 'running' && forward === 'failed') ||
    (forward !== 'running' && forward !== 'preparing' && (listenersOpen || tunAttached || vpnCreated));
}

export function homeRuntimeAppearsStarted(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean, vpnCreated: boolean, hostState: string): boolean {
  return (intent === 'started' && forward !== 'stopped') ||
    homeHasPendingCleanup(forward, listenersOpen, tunAttached, vpnCreated, hostState);
}

export function homeShouldStopRuntime(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean, vpnCreated: boolean, hostState: string): boolean {
  return hostState === 'unknown' ||
    homeRuntimeAppearsStarted(intent, forward, listenersOpen, tunAttached, vpnCreated, hostState);
}

export function homeRunActionLabel(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean, vpnCreated: boolean, hostState: string): Resource {
  if (hostState === 'unknown') {
    return $r('app.string.dash_runtime_stop_confirm');
  }
  if (homeHasPendingCleanup(forward, listenersOpen, tunAttached, vpnCreated, hostState)) {
    return $r('app.string.dash_stop_retry');
  }
  return homeRuntimeAppearsStarted(intent, forward, listenersOpen, tunAttached, vpnCreated, hostState) ?
    $r('app.string.action_disconnect') : $r('app.string.action_connect');
}

export function homeRunFailureMessage(message: string | undefined, cleanupPending: boolean, fallback: Resource): Resource {
  if (cleanupPending || message === 'vpn_detach_failed' || message === 'vpn_destroy_failed' ||
    message?.includes(';vpn_') === true) {
    return $r('app.string.dash_cleanup_required');
  }
  switch (message) {
    case 'vpn_no_profile': return $r('app.string.dash_vpn_no_profile');
    case 'vpn_authorization_denied': return $r('app.string.dash_vpn_authorization_denied');
    case 'vpn_create_failed': return $r('app.string.dash_vpn_create_failed');
    case 'vpn_attach_failed': return $r('app.string.dash_vpn_attach_failed');
    default: return fallback;
  }
}
