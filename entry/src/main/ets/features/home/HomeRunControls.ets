export function homeHasPendingCleanup(forward: string, listenersOpen: boolean, tunAttached: boolean): boolean {
  return forward === 'failed' && (listenersOpen || tunAttached);
}

export function homeRuntimeAppearsStarted(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean): boolean {
  return intent === 'started' || homeHasPendingCleanup(forward, listenersOpen, tunAttached);
}

export function homeShouldStopRuntime(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean, hostState: string): boolean {
  return hostState === 'unknown' || homeRuntimeAppearsStarted(intent, forward, listenersOpen, tunAttached);
}

export function homeRunActionLabel(intent: string, forward: string, listenersOpen: boolean,
  tunAttached: boolean, hostState: string): Resource {
  if (hostState === 'unknown') {
    return $r('app.string.dash_runtime_stop_confirm');
  }
  if (homeHasPendingCleanup(forward, listenersOpen, tunAttached)) {
    return $r('app.string.dash_stop_retry');
  }
  return intent === 'started' ? $r('app.string.action_disconnect') : $r('app.string.action_connect');
}
